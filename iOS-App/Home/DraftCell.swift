import UIKit
import AVFoundation
import SnapKit

/// 草稿网格单元：缩略图 + 右下角"草稿"标签 + 时长。
final class DraftCell: UICollectionViewCell {
    static let reuseID = "DraftCell"

    private let thumb = UIImageView()
    private let tagLabel = UILabel()
    private let durationLabel = UILabel()
    private let deleteButton = UIButton(type: .custom)
    private var currentID: UUID?
    var onDelete: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        contentView.addSubview(thumb)

        tagLabel.text = "草稿"
        tagLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        tagLabel.textColor = .white
        tagLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        tagLabel.textAlignment = .center
        tagLabel.layer.cornerRadius = 4
        tagLabel.clipsToBounds = true
        contentView.addSubview(tagLabel)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 4
        durationLabel.clipsToBounds = true
        contentView.addSubview(durationLabel)

        deleteButton.backgroundColor = UIColor.black.withAlphaComponent(0.46)
        deleteButton.tintColor = .white
        deleteButton.setImage(UIImage(named: "close_icon"), for: .normal)
        deleteButton.imageView?.contentMode = .scaleAspectFit
        deleteButton.layer.cornerRadius = 11
        deleteButton.isHidden = true
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        contentView.addSubview(deleteButton)

        thumb.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        tagLabel.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(6)
            make.width.equalTo(34)
            make.height.equalTo(16)
        }

        durationLabel.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(6)
            make.height.equalTo(16)
            make.width.greaterThanOrEqualTo(34)
        }

        deleteButton.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(3)
            make.size.equalTo(22)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onDelete = nil
        isEditing = false
    }

    var isEditing: Bool = false {
        didSet {
            deleteButton.isHidden = !isEditing
        }
    }

    func configure(with project: RecordingProject) {
        currentID = project.id
        tagLabel.isHidden = !project.isDraft
        let d = Int(project.duration.rounded())
        durationLabel.text = String(format: " %02d:%02d ", d / 60, d % 60)
        thumb.image = nil
        guard let url = project.mainVideoURL else { return }
        let targetID = project.id
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 300, height: 300)
            let img = (try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600),
                                            actualTime: nil)).map { UIImage(cgImage: $0) }
            DispatchQueue.main.async {
                if self.currentID == targetID { self.thumb.image = img }
            }
        }
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}
