import Foundation

/// The emoji Comb offers, with the words people search them by.
///
/// Curated, not enumerated. Unicode has thousands of code points including
/// every skin-tone and profession variant; a chat client needs the few
/// hundred that actually get used, and enumerating the standard would also
/// offer glyphs the running OS cannot draw. Keywords are the search index:
/// "fire" finds 🔥, and so does "lit".
enum Emoji {
    struct Entry: Identifiable, Hashable {
        let value: String
        let keywords: [String]

        var id: String { value }

        init(_ value: String, _ keywords: [String]) {
            self.value = value
            self.keywords = keywords
        }
    }

    struct Category: Identifiable, Hashable {
        let name: String
        let symbol: String
        let emoji: [Entry]

        var id: String { name }
    }

    static let categories: [Category] = [
        Category(name: "Reactions", symbol: "hand.thumbsup", emoji: [
            Entry("👍", ["thumbs up", "yes", "agree", "ok"]),
            Entry("👎", ["thumbs down", "no", "disagree"]),
            Entry("❤️", ["heart", "love", "like"]),
            Entry("🔥", ["fire", "lit", "hot", "great"]),
            Entry("🎉", ["party", "celebrate", "tada", "congrats"]),
            Entry("👏", ["clap", "applause", "bravo"]),
            Entry("🙌", ["raised hands", "praise", "yay"]),
            Entry("🙏", ["pray", "thanks", "please"]),
            Entry("💯", ["hundred", "perfect", "score"]),
            Entry("✅", ["check", "done", "complete", "tick"]),
            Entry("❌", ["cross", "no", "wrong", "cancel"]),
            Entry("👀", ["eyes", "looking", "watching"]),
            Entry("🚀", ["rocket", "ship", "launch", "fast"]),
            Entry("🐝", ["bee", "buzz", "comb"]),
            Entry("⚡️", ["zap", "lightning", "bolt", "fast"]),
            Entry("💡", ["idea", "lightbulb", "insight"]),
            Entry("🤝", ["handshake", "deal", "agree"]),
            Entry("🫡", ["salute", "yes sir", "on it"]),
        ]),
        Category(name: "Smileys", symbol: "face.smiling", emoji: [
            Entry("😀", ["grin", "happy", "smile"]),
            Entry("😂", ["laugh", "joy", "crying laughing", "lol"]),
            Entry("🤣", ["rofl", "rolling", "laugh"]),
            Entry("🙂", ["slight smile", "happy"]),
            Entry("😉", ["wink"]),
            Entry("😍", ["heart eyes", "love", "adore"]),
            Entry("🥰", ["smiling hearts", "love"]),
            Entry("😎", ["sunglasses", "cool"]),
            Entry("🤩", ["star struck", "amazed", "wow"]),
            Entry("🤔", ["thinking", "hmm", "consider"]),
            Entry("🫠", ["melting", "overwhelmed"]),
            Entry("😅", ["sweat smile", "phew", "nervous"]),
            Entry("😭", ["sob", "crying", "sad"]),
            Entry("😱", ["scream", "shock", "fear"]),
            Entry("🥲", ["tear", "bittersweet"]),
            Entry("😴", ["sleep", "tired", "zzz"]),
            Entry("🤯", ["mind blown", "explode", "shock"]),
            Entry("🫶", ["heart hands", "love", "care"]),
        ]),
        Category(name: "Work", symbol: "briefcase", emoji: [
            Entry("💻", ["laptop", "computer", "code", "work"]),
            Entry("📱", ["phone", "mobile", "iphone"]),
            Entry("🎨", ["art", "palette", "design", "paint"]),
            Entry("✏️", ["pencil", "write", "edit", "draft"]),
            Entry("📐", ["ruler", "design", "measure", "grid"]),
            Entry("📊", ["chart", "data", "stats", "graph"]),
            Entry("📌", ["pin", "important", "save"]),
            Entry("📎", ["paperclip", "attach", "file"]),
            Entry("🔗", ["link", "url", "chain"]),
            Entry("🗓️", ["calendar", "date", "schedule"]),
            Entry("⏰", ["alarm", "time", "deadline"]),
            Entry("🐛", ["bug", "issue", "defect"]),
            Entry("🔧", ["wrench", "fix", "tool"]),
            Entry("🛠️", ["tools", "build", "work"]),
            Entry("📦", ["package", "ship", "release", "box"]),
            Entry("🧪", ["test", "experiment", "lab"]),
            Entry("🔍", ["search", "magnify", "look", "review"]),
            Entry("💰", ["money", "cash", "price", "pay"]),
        ]),
        Category(name: "Objects", symbol: "cube", emoji: [
            Entry("☕️", ["coffee", "morning", "cafe"]),
            Entry("🍺", ["beer", "drink", "cheers"]),
            Entry("🍕", ["pizza", "food", "lunch"]),
            Entry("🎵", ["music", "note", "song"]),
            Entry("📷", ["camera", "photo", "picture"]),
            Entry("🎬", ["film", "video", "movie", "clapper"]),
            Entry("🕹️", ["game", "joystick", "play"]),
            Entry("🏆", ["trophy", "win", "award", "best"]),
            Entry("🎁", ["gift", "present", "surprise"]),
            Entry("🌙", ["moon", "night", "dark"]),
            Entry("☀️", ["sun", "day", "light", "morning"]),
            Entry("🌈", ["rainbow", "colour", "color", "pride"]),
            Entry("🌱", ["seedling", "grow", "new", "plant"]),
            Entry("🗑️", ["trash", "bin", "delete", "waste"]),
            Entry("🔒", ["lock", "secure", "private"]),
            Entry("🗝️", ["key", "access", "unlock"]),
            Entry("🧭", ["compass", "direction", "explore"]),
            Entry("🪄", ["magic", "wand", "auto"]),
        ]),
    ]
}
