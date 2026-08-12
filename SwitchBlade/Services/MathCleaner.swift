import Foundation

/// Repairs the formulae in Wikipedia's plaintext extracts.
///
/// `explaintext` renders `<math>` markup by flattening the MathML tree, which
/// puts every symbol on its own indented line and then appends the raw LaTeX:
///
///     is the equality
///
///       ⏎        e⏎          i⏎            π⏎        +⏎        1⏎  …
///       {\displaystyle e^{i\pi }+1=0}
///
///     where
///
/// On screen that reads as a column of stray characters followed by a line of
/// backslashes. The fix keeps the LaTeX — it's the only part carrying the
/// actual equation — converts it to something readable inline, and drops the
/// exploded tree.
enum MathCleaner {
    static func clean(_ text: String) -> String {
        // Two triggers, because text can arrive already half-repaired: an
        // earlier pass converted the LaTeX line but left the exploded tree
        // behind, so the marker is gone while the debris isn't.
        guard text.contains("\\displaystyle")
                || text.contains("\\textstyle")
                || hasFragmentRun(text)
        else {
            return text
        }

        var output: [String] = []
        var pendingFormula: String?
        // Lines that *might* be flattened-formula debris. They're only dropped
        // once a LaTeX line proves it, and flushed back otherwise.
        var buffer: [String] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // The LaTeX line closes a formula block: keep it, rendered, and
            // discard the exploded tree that preceded it.
            if let latex = extractLatex(from: trimmed) {
                buffer.removeAll()
                pendingFormula = renderLatex(latex)
                continue
            }

            // Indentation can't be the signal here: this also runs over text
            // that was stored after whitespace was collapsed, where every
            // fragment sits behind a single space. What survives collapsing is
            // the structure — a run of short symbol-ish lines immediately
            // before the LaTeX. So buffer them and decide retrospectively.
            if isFragmentCandidate(trimmed) {
                buffer.append(trimmed)
                continue
            }

            // Real prose: decide what the buffered lines were.
            flush(&buffer, into: &output)

            if let formula = pendingFormula {
                // Rejoin the formula to the prose around it, so a sentence that
                // reads "the equality <formula> where…" stays one sentence.
                if let last = output.indices.last, !output[last].isEmpty {
                    output[last] += " \(formula)"
                } else {
                    output.append(formula)
                }
                pendingFormula = nil

                if !trimmed.isEmpty {
                    // Continuation of the same sentence, not a new paragraph.
                    if trimmed.first.map({ ",.;:".contains($0) }) == true
                        || trimmed.first?.isLowercase == true {
                        output[output.indices.last!] += " \(trimmed)"
                        continue
                    }
                }
            }

            output.append(trimmed)
        }

        flush(&buffer, into: &output)
        if let formula = pendingFormula { output.append(formula) }

        return reflow(output)
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of consecutive fragment-ish lines that means "formula debris".
    ///
    /// A real paragraph never contains three single-token lines in a row, so
    /// this identifies a flattened formula even when the LaTeX that anchored it
    /// has already been converted away.
    private static let fragmentRunThreshold = 3

    private static func flush(_ buffer: inout [String], into output: inout [String]) {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return }

        let substantive = buffer.filter { !$0.isEmpty }
        guard substantive.count < fragmentRunThreshold else {
            // Long enough to be debris; drop it and leave one paragraph break.
            if output.last?.isEmpty == false { output.append("") }
            return
        }

        output.append(contentsOf: buffer)
    }

    private static func hasFragmentRun(_ text: String) -> Bool {
        var run = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if isFragmentCandidate(trimmed) {
                run += 1
                if run >= fragmentRunThreshold { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Rejoins a line that continues the previous sentence.
    ///
    /// An inline formula sits mid-sentence in the source, so the prose after it
    /// starts lowercase or with punctuation. Wikipedia paragraphs always start
    /// with a capital, which makes this unambiguous.
    private static func reflow(_ lines: [String]) -> [String] {
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard !trimmed.isEmpty else {
                if result.last?.isEmpty == false { result.append("") }
                continue
            }

            let continues = trimmed.first.map { ",.;:)".contains($0) || $0.isLowercase } ?? false

            if continues,
               let index = result.lastIndex(where: { !$0.isEmpty }),
               index >= result.count - 2 {
                let separator = ",.;:)".contains(trimmed.first!) ? "" : " "
                result[index] += separator + trimmed
                // Drop the blank line the formula left behind.
                if result.count > index + 1 { result.removeSubrange((index + 1)...) }
                continue
            }

            result.append(trimmed)
        }

        return result
    }

    /// Pulls the body out of `{\displaystyle …}` / `{\textstyle …}`, allowing
    /// for the nested braces LaTeX is full of.
    private static func extractLatex(from line: String) -> String? {
        for marker in ["{\\displaystyle", "{\\textstyle"] {
            guard let start = line.range(of: marker) else { continue }

            var depth = 0
            var body = ""
            // Start on the opening brace itself. Starting at the end of the
            // marker instead swallows the last letter of "displaystyle" and
            // mis-counts depth, which truncates the expression at its first
            // nested group.
            var index = start.lowerBound

            // Walk forward counting braces so the matching close is found even
            // when the expression contains its own groups.
            while index < line.endIndex {
                let character = line[index]
                if character == "{" {
                    depth += 1
                    if depth == 1 {
                        index = line.index(after: index)
                        continue
                    }
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
                index = line.index(after: index)
            }

            let cleaned = body
                .replacingOccurrences(of: "\\displaystyle", with: "")
                .replacingOccurrences(of: "\\textstyle", with: "")
                .trimmingCharacters(in: .whitespaces)

            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Whether a line *could* be one symbol of a flattened formula.
    ///
    /// Deliberately permissive — a false positive costs nothing, because a
    /// buffered line is only discarded when a LaTeX line follows it and is put
    /// back verbatim otherwise.
    private static func isFragmentCandidate(_ trimmed: String) -> Bool {
        // Blank lines inside a formula block are part of it.
        if trimmed.isEmpty { return true }

        // Real prose in these extracts is far longer than this.
        guard trimmed.count <= 12 else { return false }

        // A fragment is always a single token: "0.999", "=", "…", "1.".
        guard !trimmed.contains(" ") else { return false }

        // No letters at all is conclusive — digits, operators, ellipses.
        let letters = trimmed.filter { $0.isLetter }
        if letters.isEmpty { return true }

        // Otherwise a lone variable ("e", "i", "π", "dx") qualifies, but a
        // short word ("where", "and", "is") does not.
        return letters.count <= 2
    }

    /// Turns LaTeX into something readable in a sentence.
    ///
    /// Not a typesetter — just enough that `e^{i\pi }+1=0` reads as
    /// `e^(iπ) + 1 = 0` rather than a line of backslashes.
    private static func renderLatex(_ latex: String) -> String {
        var text = latex

        let symbols: [String: String] = [
            "\\pi": "π", "\\alpha": "α", "\\beta": "β", "\\gamma": "γ",
            "\\delta": "δ", "\\epsilon": "ε", "\\theta": "θ", "\\lambda": "λ",
            "\\mu": "μ", "\\sigma": "σ", "\\phi": "φ", "\\omega": "ω",
            "\\Delta": "Δ", "\\Sigma": "Σ", "\\Omega": "Ω",
            "\\infty": "∞", "\\times": "×", "\\cdot": "·", "\\div": "÷",
            "\\pm": "±", "\\mp": "∓", "\\leq": "≤", "\\geq": "≥",
            "\\neq": "≠", "\\approx": "≈", "\\equiv": "≡", "\\sim": "∼",
            "\\rightarrow": "→", "\\leftarrow": "←", "\\Rightarrow": "⇒",
            "\\in": "∈", "\\subset": "⊂", "\\forall": "∀", "\\exists": "∃",
            "\\partial": "∂", "\\nabla": "∇", "\\int": "∫", "\\sum": "∑",
            "\\prod": "∏", "\\sqrt": "√", "\\ldots": "…", "\\dots": "…",
            // Leading space keeps these from fusing onto the previous symbol,
            // which turns "i \sin x" into "isin x".
            "\\sin": " sin", "\\cos": " cos", "\\tan": " tan",
            "\\log": " log", "\\ln": " ln", "\\exp": " exp", "\\lim": " lim"
        ]

        // Longest first, so \Delta isn't eaten by \delta's prefix.
        for key in symbols.keys.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: key, with: symbols[key]!)
        }

        // \frac{a}{b} reads better as a/b than as either brace form.
        text = text.replacingOccurrences(
            of: #"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#,
            with: "($1)/($2)",
            options: .regularExpression
        )

        // Superscripts and subscripts become parenthesised, which survives in
        // a plain-text label.
        text = text.replacingOccurrences(
            of: #"\^\{([^{}]*)\}"#, with: "^($1)", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"_\{([^{}]*)\}"#, with: "_($1)", options: .regularExpression
        )

        // Remaining LaTeX plumbing.
        text = text
            .replacingOccurrences(of: #"\\(?:left|right|mathrm|mathbf|text|operatorname)"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\!", with: "")
            .replacingOccurrences(of: "\\", with: "")

        // Breathing room around comparators, without doubling existing spaces.
        for op in ["=", "+", "≤", "≥", "≠", "≈", "<", ">"] {
            text = text.replacingOccurrences(of: op, with: " \(op) ")
        }

        return text
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +\)"#, with: ")", options: .regularExpression)
            .replacingOccurrences(of: #"\( +"#, with: "(", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
