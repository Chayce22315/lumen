import Foundation
import LumenFoundation

/// Renders a `PeriodReport` as GitHub-flavoured Markdown. The output depends only on the report,
/// so it is stable enough to snapshot.
public enum ReportMarkdownRenderer {
    typealias Format = AnalyticsFormatting

    public static func render(_ report: PeriodReport) -> String {
        var lines: [String] = []
        lines.append("# Report: \(Format.range(report.range))")
        lines.append("")
        lines.append(coverage(report))
        lines.append("")

        lines.append("## Summary")
        lines.append("")
        lines.append("| Measure | This period | Previous period | Change |")
        lines.append("| --- | ---: | ---: | ---: |")
        let unit = report.unit
        lines.append(summaryRow("Completed \(unit.plural)", report.completedComparison))
        if let created = report.createdComparison {
            lines.append(summaryRow("Created \(unit.plural)", created))
        }
        if let focus = report.focusComparison {
            lines.append(summaryRow("Focus events", focus))
        }
        lines.append("")
        lines.append("- Current streak: \(Format.days(report.currentStreak))")
        lines.append("- Longest streak in this period: \(Format.days(report.longestStreak))")
        if let weekday = report.bestWeekday {
            lines.append("- Best weekday: \(weekday.fullName)")
        }
        lines.append("")

        lines.append("## Per day")
        lines.append("")
        if report.dailyCompleted.isEmpty {
            lines.append("This period has not started yet.")
        } else if let created = report.dailyCreated {
            lines.append("| Day | Completed | Created |")
            lines.append("| --- | ---: | ---: |")
            for point in report.dailyCompleted.points {
                let createdValue = created.value(on: point.day) ?? 0
                lines.append("| \(Format.shortDay(point.day)) | \(Format.number(point.value)) | \(Format.number(createdValue)) |")
            }
        } else {
            lines.append("| Day | Completed |")
            lines.append("| --- | ---: |")
            for point in report.dailyCompleted.points {
                lines.append("| \(Format.shortDay(point.day)) | \(Format.number(point.value)) |")
            }
        }
        lines.append("")

        lines.append("## Activity by module")
        lines.append("")
        if report.modules.isEmpty {
            lines.append("No activity was recorded in this period.")
        } else {
            lines.append("| Module | Events |")
            lines.append("| --- | ---: |")
            for module in report.modules {
                lines.append("| \(cell(module.displayName)) | \(module.count) |")
            }
        }
        lines.append("")

        lines.append("## Insights")
        lines.append("")
        if report.insights.isEmpty {
            lines.append("Not enough recorded activity for insights yet.")
        } else {
            for insight in report.insights {
                lines.append("- **\(inline(insight.title))** — \(inline(insight.detail))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func coverage(_ report: PeriodReport) -> String {
        guard report.range.start <= report.asOf else {
            return "This period has not started yet."
        }
        let covered = DayRange(start: report.range.start, end: report.asOf)
        let running = report.asOf < report.range.end ? " so far" : ""
        return "Covers \(Format.range(covered))\(running), compared with \(Format.range(report.previousRange))."
    }

    private static func summaryRow(_ label: String, _ comparison: Comparison) -> String {
        let change: String
        if let percent = comparison.percentChange {
            change = Format.signedPercent(percent)
        } else {
            change = comparison.current > 0 ? "new" : "—"
        }
        return "| \(cell(label)) | \(Format.number(comparison.current)) | \(Format.number(comparison.previous)) | \(change) |"
    }

    /// Escapes text placed in a table cell: pipes would end the cell, newlines the row.
    private static func cell(_ text: String) -> String {
        inline(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Keeps configured names and generated text on one line.
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
