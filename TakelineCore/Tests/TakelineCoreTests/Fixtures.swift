@testable import TakelineCore

let bakery = """
Mais comment est-ce qu'ils arrivent à vendre leur pain aussi peu cher, sans perdre d'argent ? En réalité, c'est une vraie leçon d'organisation.
Premièrement, la quasi-totalité de leurs fours sont électriques, ce qui réduit nettement les factures d'énergie. Parce que oui, le gaz, ça coûte cher.
Mais ils sont carrément allés encore plus loin. Ils se sont associés directement avec des meuniers de la région pour choisir des farines pensées pour cet usage.
Des baguettes super simples à produire, toujours croustillantes et dont la fabrication coûte beaucoup moins cher. [pause] La chaîne Fournil a un avantage décisif.
"""

/// Feeds `spoken` one word at a time, like an engine that finalizes every word.
@discardableResult
func read(_ spoken: String, with tracker: inout Tracker, heard: inout [String]) -> [Tracker.Move] {
    var moves: [Tracker.Move] = []
    for word in spoken.split(separator: " ") {
        heard.append(String(word))
        if let move = tracker.update(heard: [Array(heard.suffix(14))]) { moves.append(move) }
    }
    return moves
}

func index(of phrase: String, in script: Script) -> Int {
    let keys = phrase.split(separator: " ").map { Script.key($0) }
    let words = script.words.map(\.key)
    return (0...(words.count - keys.count)).first { Array(words[$0..<$0 + keys.count]) == keys }!
}
