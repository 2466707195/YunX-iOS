import Foundation

// MARK: - 时间格式化便捷入口
//
// 需求很朴素：按固定 pattern 输出中文环境的时间字符串。
// 不要用 `Date.FormatStyle` —— 它没法直接吃 "yyyy-MM-dd HH:mm" 这种 pattern，
// 想自定义只能自己拼 DateFormatter，索性封一个。
//
// 注意：DateFormatter 创建成本不低，列表里逐行调用时要靠调用方控制频率；
// 这里保留每次新建，是为了避免共享实例的线程安全问题和 pattern 串味。

extension Date {
    func formatted(_ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: self)
    }
}
