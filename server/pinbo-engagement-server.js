const { randomUUID } = require('node:crypto');
const { createServer } = require('node:http');
const { existsSync, mkdirSync } = require('node:fs');
const { readFile, rename, writeFile } = require('node:fs/promises');
const { dirname, resolve } = require('node:path');

const port = positiveInteger(process.env.PORT, 1315);
const host = process.env.HOST || '127.0.0.1';
const storeFile = resolve(process.env.ENGAGEMENT_STORE_FILE || resolve(__dirname, 'data/engagement.json'));
const jsonContentType = 'application/json; charset=utf-8';
const maxRequestBodyBytes = 16 * 1024;
const maxAuthorLength = 32;
const maxEmailLength = 120;
const maxUDIDLength = 100;
const maxCommentLength = 500;
const maxTopLevelComments = 300;
const maxLikedVisitorIds = 10000;
const streamClients = new Set();
let writeQueue = Promise.resolve();
let storeDirectoryReady = false;

const server = createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    const statusCode = errorStatusCode(error);
    if (statusCode >= 500) console.error(error);
    sendJSON(response, { ok: false, message: errorMessage(error) }, statusCode);
  });
});

server.listen(port, host, () => {
  console.log(`Pinbo 互动服务已启动：http://${host}:${port}`);
  console.log(`互动数据文件：${storeFile}`);
});

/** 路由所有 Pinbo 点赞、评论和健康检查请求。 */
async function handleRequest(request, response) {
  const method = request.method || 'GET';
  const url = new URL(request.url || '/', `http://${request.headers.host || `${host}:${port}`}`);
  const pathname = normalizedPath(url.pathname);

  if (method === 'OPTIONS') {
    sendNoContent(response, 204);
    return;
  }

  if (method === 'GET' && pathname === '/health') {
    sendJSON(response, { ok: true, service: 'pinbo-engagement', runtime: 'node' });
    return;
  }

  if (method === 'GET' && pathname === '/api/engagement') {
    sendJSON(response, { ok: true, ...(await loadSnapshot()) });
    return;
  }

  if (method === 'GET' && pathname === '/api/engagement/stream') {
    await openStream(request, response);
    return;
  }

  if (method === 'POST' && pathname === '/api/likes') {
    await handleLike(request, response);
    return;
  }

  if (method === 'POST' && pathname === '/api/comments') {
    await handleComment(request, response);
    return;
  }

  sendJSON(response, { ok: false, message: 'Not found' }, 404);
}

/** 处理点赞请求，同一访客标识只累计一次。 */
async function handleLike(request, response) {
  const body = await readJSONBody(request);
  const visitorId = normalizedVisitorId(body.visitorId);
  const result = await updateStore((store) => {
    const likedVisitorIds = new Set(store.likes.visitorIds);
    const alreadyLiked = visitorId ? likedVisitorIds.has(visitorId) : false;

    if (!alreadyLiked) {
      store.likes.count += 1;
      if (visitorId) {
        likedVisitorIds.add(visitorId);
        store.likes.visitorIds = Array.from(likedVisitorIds).slice(-maxLikedVisitorIds);
      }
    }

    return { liked: !alreadyLiked, snapshot: serializeStore(store) };
  });

  sendJSON(response, { ok: true, liked: result.liked, ...result.snapshot });
}

/** 处理体验申请评论，完整邮箱和 UDID 仅保存在服务端。 */
async function handleComment(request, response) {
  const body = await readJSONBody(request);
  const author = normalizedAuthor(body.author);
  const email = normalizedRequiredEmail(body.email);
  const udid = normalizedRequiredUDID(body.udid);
  const content = normalizedCommentContent(body.content);

  const result = await updateStore((store) => {
    const createdAt = new Date().toISOString();
    const commentId = randomUUID();
    store.comments.unshift({ id: commentId, author, email, udid, content, createdAt });
    store.comments = store.comments.slice(0, maxTopLevelComments);
    return { commentId, snapshot: serializeStore(store) };
  });

  sendJSON(response, { ok: true, commentId: result.commentId, ...result.snapshot });
}

/** 打开 SSE 通道，评论或点赞更新后推送最新快照。 */
async function openStream(request, response) {
  applyCORS(response);
  response.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no'
  });
  response.write(': connected\n\n');
  streamClients.add(response);

  request.on('close', () => {
    streamClients.delete(response);
  });

  const snapshot = await loadSnapshot();
  response.write(`event: engagement\ndata: ${JSON.stringify(snapshot)}\n\n`);
}

/** 串行更新 JSON 存储，避免并发写入覆盖。 */
function updateStore(updater) {
  const task = writeQueue.then(async () => {
    const store = await loadStore();
    const result = updater(store);
    await saveStore(store);
    broadcastSnapshot(result.snapshot);
    return result;
  });
  writeQueue = task.then(() => undefined, () => undefined);
  return task;
}

/** 读取并序列化当前互动快照。 */
async function loadSnapshot() {
  return serializeStore(await loadStore());
}

/** 从磁盘读取互动数据。 */
async function loadStore() {
  try {
    const rawValue = JSON.parse(await readFile(storeFile, 'utf8'));
    return normalizedStore(rawValue);
  } catch (error) {
    if (error && error.code === 'ENOENT') return emptyStore();
    console.error('读取互动数据失败，已回退为空数据。', error);
    return emptyStore();
  }
}

/** 原子写入互动数据文件。 */
async function saveStore(store) {
  ensureStoreDirectory();
  const tempFile = `${storeFile}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tempFile, `${JSON.stringify(normalizedStore(store), null, 2)}\n`, 'utf8');
  await rename(tempFile, storeFile);
}

/** 确保数据目录存在。 */
function ensureStoreDirectory() {
  if (storeDirectoryReady) return;
  const directory = dirname(storeFile);
  if (!existsSync(directory)) mkdirSync(directory, { recursive: true });
  storeDirectoryReady = true;
}

/** 向所有在线页面推送最新快照。 */
function broadcastSnapshot(snapshot) {
  const payload = `event: engagement\ndata: ${JSON.stringify(snapshot)}\n\n`;
  for (const client of streamClients) {
    client.write(payload);
  }
}

/** 读取并解析 JSON 请求体。 */
async function readJSONBody(request) {
  const chunks = [];
  let totalBytes = 0;

  for await (const chunk of request) {
    totalBytes += chunk.length;
    if (totalBytes > maxRequestBodyBytes) throw new HTTPError('请求内容过大', 413);
    chunks.push(chunk);
  }

  if (chunks.length === 0) return {};

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HTTPError('JSON 格式不正确', 400);
  }
}

/** 返回空互动数据结构。 */
function emptyStore() {
  return { likes: { count: 0, visitorIds: [] }, comments: [] };
}

/** 归一化磁盘数据，避免脏数据影响接口。 */
function normalizedStore(rawValue) {
  if (!isRecord(rawValue)) return emptyStore();
  const likes = isRecord(rawValue.likes) ? rawValue.likes : {};
  const visitorIds = Array.isArray(likes.visitorIds) ? likes.visitorIds.filter(isString).slice(-maxLikedVisitorIds) : [];
  const count = Math.max(positiveNumber(likes.count), visitorIds.length);
  const comments = Array.isArray(rawValue.comments) ? rawValue.comments.map(normalizedStoredComment).filter(Boolean) : [];
  return { likes: { count, visitorIds }, comments: comments.slice(0, maxTopLevelComments) };
}

/** 归一化已存储的评论。 */
function normalizedStoredComment(rawValue) {
  if (!isRecord(rawValue)) return null;
  const id = normalizedStoredId(rawValue.id);
  const author = normalizedAuthor(rawValue.author);
  const email = normalizedStoredEmail(rawValue.email);
  const udid = normalizedStoredUDID(rawValue.udid);
  const content = normalizedCommentContent(rawValue.content);
  const createdAt = normalizedCreatedAt(rawValue.createdAt);
  return id && email && udid ? { id, author, email, udid, content, createdAt } : null;
}

/** 序列化可公开展示的数据，隐藏完整邮箱和 UDID。 */
function serializeStore(store) {
  return {
    likes: { count: store.likes.count },
    comments: store.comments.map((comment) => ({
      id: comment.id,
      author: comment.author,
      emailMasked: maskedEmail(comment.email),
      udidMasked: maskedUDID(comment.udid),
      content: comment.content,
      createdAt: comment.createdAt
    }))
  };
}

/** 归一化访客标识。 */
function normalizedVisitorId(rawValue) {
  if (!isString(rawValue)) return null;
  const trimmedValue = rawValue.trim();
  return /^[A-Za-z0-9_-]{16,80}$/.test(trimmedValue) ? trimmedValue : null;
}

/** 归一化昵称。 */
function normalizedAuthor(rawValue) {
  const author = normalizedText(rawValue, maxAuthorLength);
  return author || '访客';
}

/** 校验并归一化邮箱。 */
function normalizedRequiredEmail(rawValue) {
  const email = normalizedText(rawValue, maxEmailLength).toLowerCase();
  if (!email) throw new HTTPError('请填写邮箱', 400);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HTTPError('邮箱格式不正确', 400);
  return email;
}

/** 校验并归一化设备 UDID。 */
function normalizedRequiredUDID(rawValue) {
  const udid = normalizedText(rawValue, maxUDIDLength).replace(/\s+/g, '');
  if (!udid) throw new HTTPError('请填写设备 UDID', 400);
  if (!/^[A-Za-z0-9-]{8,100}$/.test(udid)) throw new HTTPError('设备 UDID 格式不正确', 400);
  return udid.toUpperCase();
}

/** 归一化已存储邮箱。 */
function normalizedStoredEmail(rawValue) {
  const email = normalizedText(rawValue, maxEmailLength).toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : '';
}

/** 归一化已存储 UDID。 */
function normalizedStoredUDID(rawValue) {
  const udid = normalizedText(rawValue, maxUDIDLength).replace(/\s+/g, '');
  return /^[A-Za-z0-9-]{8,100}$/.test(udid) ? udid.toUpperCase() : '';
}

/** 归一化留言内容，未填写时给出默认申请文案。 */
function normalizedCommentContent(rawValue) {
  return normalizedText(rawValue, maxCommentLength) || '想体验手机版 Pinbo';
}

/** 归一化普通文本并去掉控制字符。 */
function normalizedText(rawValue, maxLength) {
  if (!isString(rawValue)) return '';
  const normalizedValue = rawValue
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '')
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  return Array.from(normalizedValue).slice(0, maxLength).join('');
}

/** 归一化评论 ID。 */
function normalizedStoredId(rawValue) {
  if (!isString(rawValue)) return null;
  const trimmedValue = rawValue.trim();
  return trimmedValue.length > 0 && trimmedValue.length <= 80 ? trimmedValue : null;
}

/** 归一化创建时间。 */
function normalizedCreatedAt(rawValue) {
  if (!isString(rawValue)) return new Date().toISOString();
  const parsedTime = Date.parse(rawValue);
  return Number.isFinite(parsedTime) ? new Date(parsedTime).toISOString() : new Date().toISOString();
}

/** 脱敏邮箱地址。 */
function maskedEmail(email) {
  const [name, domain] = email.split('@');
  const safeName = name.length <= 1 ? `${name || '*'}***` : `${name.slice(0, 2)}***`;
  return `${safeName}@${domain}`;
}

/** 脱敏设备 UDID。 */
function maskedUDID(udid) {
  if (udid.length <= 12) return `${udid.slice(0, 2)}***${udid.slice(-2)}`;
  return `${udid.slice(0, 6)}…${udid.slice(-4)}`;
}

/** 发送 JSON 响应。 */
function sendJSON(response, payload, statusCode = 200) {
  applyCORS(response);
  response.writeHead(statusCode, { 'Content-Type': jsonContentType });
  response.end(JSON.stringify(payload));
}

/** 发送无内容响应。 */
function sendNoContent(response, statusCode) {
  applyCORS(response);
  response.writeHead(statusCode);
  response.end();
}

/** 设置跨域响应头。 */
function applyCORS(response) {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Methods', 'GET,HEAD,POST,OPTIONS');
  response.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
}

/** 规整请求路径，同时兼容反代前后的路径。 */
function normalizedPath(pathname) {
  const decodedPath = safelyDecodeURIComponent(pathname).replace(/\/+$/, '') || '/';
  if (decodedPath.startsWith('/pinbo/api/')) return decodedPath.slice('/pinbo'.length);
  if (decodedPath === '/pinbo/api') return '/api';
  return decodedPath;
}

/** 安全解码 URL 路径。 */
function safelyDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/** 转换正整数配置。 */
function positiveInteger(rawValue, fallback) {
  const value = Number(rawValue);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

/** 转换正整数存量数据。 */
function positiveNumber(rawValue) {
  return typeof rawValue === 'number' && Number.isFinite(rawValue) && rawValue > 0 ? Math.floor(rawValue) : 0;
}

/** 读取错误消息。 */
function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

/** 读取业务错误携带的 HTTP 状态码。 */
function errorStatusCode(error) {
  return error instanceof HTTPError ? error.statusCode : 500;
}

/** 判断值是否为对象。 */
function isRecord(rawValue) {
  return typeof rawValue === 'object' && rawValue !== null;
}

/** 判断值是否为字符串。 */
function isString(rawValue) {
  return typeof rawValue === 'string';
}

/** 携带 HTTP 状态码的业务错误。 */
class HTTPError extends Error {
  constructor(message, statusCode) {
    super(message);
    this.statusCode = statusCode;
  }
}
