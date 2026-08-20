import UIKit

enum AppTheme {
    static let primary = UIColor(red: 1.00, green: 0.24, blue: 0.08, alpha: 1.00)
    static let primaryPressed = UIColor(red: 0.91, green: 0.12, blue: 0.03, alpha: 1.00)
    static let primaryShadow = UIColor(red: 1.00, green: 0.30, blue: 0.08, alpha: 1.00)
    static let destructive = UIColor(red: 0.96, green: 0.15, blue: 0.08, alpha: 1.00)
    static let gradientColors = [
        UIColor(red: 1.00, green: 0.20, blue: 0.07, alpha: 1.00),
        UIColor(red: 1.00, green: 0.46, blue: 0.13, alpha: 1.00),
        UIColor(red: 0.93, green: 0.10, blue: 0.02, alpha: 1.00),
    ]
}

extension UIButton {
    func applyAppPrimaryButtonStyle(cornerRadius: CGFloat, shadow: Bool = false) {
        backgroundColor = AppTheme.primary
        setTitleColor(.white, for: .normal)
        tintColor = .white
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous

        guard shadow else { return }
        layer.shadowColor = AppTheme.primaryShadow.cgColor
        layer.shadowOpacity = 0.42
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 7)
    }
}
