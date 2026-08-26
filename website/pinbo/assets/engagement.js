(() => {
  const root = document.querySelector('[data-engagement-root]');
  if (!root) return;

  const api = {
    engagement: root.dataset.engagementApi,
    like: root.dataset.likeApi,
    comment: root.dataset.commentApi,
    stream: root.dataset.streamApi
  };

  const elements = {
    likeButton: root.querySelector('[data-like-button]'),
    likeLabel: root.querySelector('[data-like-label]'),
    likeCount: root.querySelector('[data-like-count]'),
    status: root.querySelector('[data-engagement-status]'),
    commentCount: root.querySelector('[data-comment-count]'),
    commentForm: root.querySelector('[data-comment-form]'),
    commentList: root.querySelector('[data-comment-list]')
  };

  const storageKeys = {
    visitorId: 'pinbo:visitor-id',
    liked: 'pinbo:liked'
  };

  const visitorId = currentVisitorId();
  let lastSnapshot = { likes: { count: 0 }, comments: [] };
  let streamConnected = false;

  bindEvents();
  syncLikeState();
  refreshEngagement(false);
  connectRealtimeUpdates();
  window.setInterval(() => refreshEngagement(true), 30000);

  /** 绑定点赞和体验申请表单事件。 */
  function bindEvents() {
    elements.likeButton?.addEventListener('click', handleLikeClick);
    elements.commentForm?.addEventListener('submit', (event) => {
      event.preventDefault();
      submitCommentForm(elements.commentForm);
    });
  }

  /** 提交当前访客点赞，同一浏览器只计一次。 */
  async function handleLikeClick() {
    if (!api.like || isLiked()) return;

    setLikeLoading(true);
    try {
      const payload = await requestJSON(api.like, {
        method: 'POST',
        body: JSON.stringify({ visitorId })
      });
      setLiked();
      renderSnapshot(payload);
      setStatus(payload.liked === false ? '你已经点过赞，已刷新最新数量。' : '感谢点赞，已同步最新数量。', 'success');
    } catch (error) {
      setStatus(readableError(error, '点赞失败，请稍后重试。'), 'error');
    } finally {
      setLikeLoading(false);
      syncLikeState();
    }
  }

  /** 提交邮箱、UDID 和留言，便于后续邀请体验手机版。 */
  async function submitCommentForm(form) {
    if (!form || !api.comment || form.dataset.submitting === 'true') return;

    const formData = new FormData(form);
    const author = String(formData.get('author') || '').trim();
    const email = String(formData.get('email') || '').trim();
    const udid = String(formData.get('udid') || '').trim();
    const content = String(formData.get('content') || '').trim();

    if (!email || !udid) {
      setStatus('请填写邮箱和设备 UDID，方便我们邀请你体验手机版。', 'error');
      return;
    }

    form.dataset.submitting = 'true';
    setFormDisabled(form, true);
    try {
      const payload = await requestJSON(api.comment, {
        method: 'POST',
        body: JSON.stringify({ author, email, udid, content, visitorId })
      });
      form.reset();
      renderSnapshot(payload);
      setStatus('已收到体验申请，邮箱和 UDID 在页面中已脱敏展示。', 'success');
    } catch (error) {
      setStatus(readableError(error, '提交失败，请稍后重试。'), 'error');
    } finally {
      form.dataset.submitting = 'false';
      setFormDisabled(form, false);
    }
  }

  /** 拉取点赞和评论快照，失败时保留当前页面内容。 */
  async function refreshEngagement(silent) {
    if (!api.engagement) return;

    try {
      const payload = await requestJSON(api.engagement);
      renderSnapshot(payload);
      if (!silent && !streamConnected) setStatus('最新互动数据已加载。', 'success');
    } catch (error) {
      if (!silent) setStatus(readableError(error, '暂时无法加载互动数据。'), 'error');
    }
  }

  /** 连接实时更新通道，不支持时自动降级为定时刷新。 */
  function connectRealtimeUpdates() {
    if (!api.stream || !window.EventSource) return;

    const source = new EventSource(api.stream);
    source.addEventListener('open', () => {
      streamConnected = true;
    });
    source.addEventListener('engagement', (event) => {
      try {
        renderSnapshot(JSON.parse(event.data));
      } catch {
        refreshEngagement(true);
      }
    });
    source.addEventListener('error', () => {
      streamConnected = false;
    });
  }

  /** 把服务端返回的数据渲染到点赞数和评论列表。 */
  function renderSnapshot(payload) {
    lastSnapshot = normalizedSnapshot(payload);
    elements.likeCount.textContent = formatNumber(lastSnapshot.likes.count);
    elements.commentCount.textContent = `${lastSnapshot.comments.length} 条留言`;
    renderComments(lastSnapshot.comments);
  }

  /** 渲染公开评论列表，邮箱和 UDID 只显示服务端脱敏值。 */
  function renderComments(comments) {
    elements.commentList.replaceChildren();
    if (!comments.length) {
      elements.commentList.append(createElement('p', 'comment-empty', '还没有留言，欢迎第一个留下体验申请。'));
      return;
    }

    for (const comment of comments) {
      const card = createElement('article', 'comment-card');
      const contact = createElement('div', 'comment-contact');
      contact.append(
        createElement('span', '', `邮箱：${comment.emailMasked || '已填写'}`),
        createElement('span', '', `UDID：${comment.udidMasked || '已填写'}`)
      );
      card.append(createCommentHeader(comment), contact, createElement('p', 'comment-content', comment.content));
      elements.commentList.append(card);
    }
  }

  /** 创建评论标题行，包含昵称和提交时间。 */
  function createCommentHeader(comment) {
    const header = createElement('div', 'comment-meta');
    const author = createElement('strong', '', comment.author || '访客');
    const time = createElement('time', '', formatDate(comment.createdAt));
    time.dateTime = comment.createdAt;
    header.append(author, time);
    return header;
  }

  /** 发起 JSON 请求并统一处理错误消息。 */
  async function requestJSON(url, options = {}) {
    const response = await fetch(url, {
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json'
      },
      ...options
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) throw new Error(payload.message || '请求失败');
    return payload;
  }

  /** 归一化服务端快照，避免异常数据影响页面展示。 */
  function normalizedSnapshot(payload) {
    const comments = Array.isArray(payload?.comments) ? payload.comments.map(normalizedComment).filter(Boolean) : [];
    return {
      likes: { count: positiveNumber(payload?.likes?.count) },
      comments
    };
  }

  /** 归一化单条评论结构。 */
  function normalizedComment(comment) {
    if (!comment || typeof comment !== 'object') return null;
    return {
      id: String(comment.id || ''),
      author: String(comment.author || '访客'),
      emailMasked: String(comment.emailMasked || ''),
      udidMasked: String(comment.udidMasked || ''),
      content: String(comment.content || '想体验手机版 Pinbo'),
      createdAt: String(comment.createdAt || new Date().toISOString())
    };
  }

  /** 根据本地记录同步点赞按钮状态。 */
  function syncLikeState() {
    const liked = isLiked();
    elements.likeButton.disabled = liked;
    elements.likeLabel.textContent = liked ? '已点赞' : '点赞';
  }

  /** 切换点赞按钮加载态。 */
  function setLikeLoading(isLoading) {
    elements.likeButton.disabled = isLoading || isLiked();
    elements.likeLabel.textContent = isLoading ? '同步中...' : (isLiked() ? '已点赞' : '点赞');
  }

  /** 批量禁用或恢复表单控件。 */
  function setFormDisabled(form, disabled) {
    for (const field of form.querySelectorAll('input, textarea, button')) {
      field.disabled = disabled;
    }
  }

  /** 更新互动模块状态提示。 */
  function setStatus(message, type) {
    elements.status.textContent = message;
    elements.status.dataset.status = type;
  }

  /** 获取当前浏览器访客标识。 */
  function currentVisitorId() {
    const storedId = readStorage(storageKeys.visitorId);
    if (/^[A-Za-z0-9_-]{16,80}$/.test(storedId || '')) return storedId;

    const newId = createVisitorId();
    writeStorage(storageKeys.visitorId, newId);
    return newId;
  }

  /** 创建兼容旧浏览器的访客标识。 */
  function createVisitorId() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID();
    const randomPart = `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`;
    return `pb_${randomPart}`.slice(0, 80);
  }

  /** 判断当前浏览器是否已点过赞。 */
  function isLiked() {
    return readStorage(storageKeys.liked) === '1';
  }

  /** 记录当前浏览器已点赞。 */
  function setLiked() {
    writeStorage(storageKeys.liked, '1');
  }

  /** 安全读取本地存储。 */
  function readStorage(key) {
    try {
      return window.localStorage.getItem(key);
    } catch {
      return null;
    }
  }

  /** 安全写入本地存储。 */
  function writeStorage(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch {
      // localStorage 不可用时忽略，接口仍可正常提交。
    }
  }

  /** 创建带文本的 DOM 元素。 */
  function createElement(tagName, className, text) {
    const element = document.createElement(tagName);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  /** 格式化点赞数量。 */
  function formatNumber(value) {
    return positiveNumber(value).toLocaleString('zh-CN');
  }

  /** 格式化评论提交时间。 */
  function formatDate(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '刚刚';
    return new Intl.DateTimeFormat('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(date);
  }

  /** 读取可展示的错误信息。 */
  function readableError(error, fallback) {
    return error instanceof Error && error.message ? error.message : fallback;
  }

  /** 把非正常数字归零。 */
  function positiveNumber(value) {
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  }
})();
