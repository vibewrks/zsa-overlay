import Foundation

/// Verified QMK matrix positions of the Moonlander Mark I, in Oryx key order.
///
/// `oryxToMatrix[i]` is the position the firmware reports over raw HID for Oryx key
/// `i` (the same id as `PhysicalKey.id` in the bundled keymap, where 32 and 68 are the
/// two 2u thumb keys). The table is the matrix-to-index mapping from the Keymapp
/// frontend bundle, mirrored from `scripts/import-keymapp.py` (`ORYX_TO_MATRIX`) and
/// cross-checked against the bundled `rba3al` layout.
nonisolated enum MoonlanderMatrix {
    /// The matrix is 12 rows by 7 columns; not every cell holds a switch — the thumb
    /// clusters and the last rows are sparse.
    private static let rowCount = 12
    private static let columnCount = 7

    static let oryxToMatrix: [(row: Int, column: Int)] = [
        (0, 0), (0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6),           // 0...6
        (1, 0), (1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6),           // 7...13
        (2, 0), (2, 1), (2, 2), (2, 3), (2, 4), (2, 5), (2, 6),           // 14...20
        (3, 0), (3, 1), (3, 2), (3, 3), (3, 4), (3, 5),                   // 21...26
        (4, 0), (4, 1), (4, 2), (4, 3), (4, 4),                           // 27...31
        (5, 3), (5, 0), (5, 1), (5, 2),                                   // 32...35, 32 is the left 2u thumb key
        (6, 0), (6, 1), (6, 2), (6, 3), (6, 4), (6, 5), (6, 6),           // 36...42
        (7, 0), (7, 1), (7, 2), (7, 3), (7, 4), (7, 5), (7, 6),           // 43...49
        (8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 6),           // 50...56
        (9, 1), (9, 2), (9, 3), (9, 4), (9, 5), (9, 6),                   // 57...62
        (10, 2), (10, 3), (10, 4), (10, 5), (10, 6),                      // 63...67
        (11, 3), (11, 4), (11, 5), (11, 6),                               // 68...71, 68 is the right 2u thumb key
    ]

    /// `oryxToMatrix` inverted once; `nil` marks a cell with no switch. Indexed
    /// `row * columnCount + column`, so a lookup never scans the table.
    private static let matrixToOryx: [Int?] = {
        var table = [Int?](repeating: nil, count: rowCount * columnCount)
        for (oryxIndex, position) in oryxToMatrix.enumerated() {
            table[position.row * columnCount + position.column] = oryxIndex
        }
        return table
    }()

    /// The Oryx key id for a matrix position, or `nil` when the pair is not one of the
    /// board's 72 keys.
    static func oryxIndex(forRow row: Int, column: Int) -> Int? {
        guard (0..<rowCount).contains(row), (0..<columnCount).contains(column) else { return nil }
        return matrixToOryx[row * columnCount + column]
    }
}
