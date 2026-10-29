import Foundation

/// Traditional Chinese and English (non-functional requirement: 在地化).
/// Keys are the English text; Traditional Chinese is used when it is the preferred language.
enum L10n {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static let zh: [String: String] = [
        "Search": "搜尋",
        "No Results": "沒有結果",
        "Open Launchpad": "打開 Launchpad",
        "Settings…": "設定…",
        "Import Old Launchpad Layout…": "匯入舊 Launchpad 佈局…",
        "Quit Launchpad": "結束 Launchpad",
        "About Launchpad": "關於 Launchpad",
        "Edit": "編輯",
        "Undo": "還原", "Redo": "重做", "Cut": "剪下", "Copy": "拷貝", "Paste": "貼上", "Select All": "全選",
        "Open": "打開",
        "Show in Finder": "在 Finder 中顯示",
        "Hide": "隱藏",
        "Move to Trash…": "移到垃圾桶…",
        "Rename": "重新命名",
        "Ungroup Folder": "解散資料夾",
        "Edit Layout": "編輯佈局",
        "Done Editing": "完成編輯",
        "Cancel": "取消",
        "Move to Trash": "移到垃圾桶",
        "OK": "好",
        "Move “%@” to the Trash?": "要將「%@」移到垃圾桶嗎？",
        "The app will be removed from this Mac. You can restore it from the Trash.": "App 會從這台 Mac 移除，之後可從垃圾桶還原。",
        "Could not move “%@” to the Trash.": "無法將「%@」移到垃圾桶。",
        "Could not open “%@”.": "無法打開「%@」。",
        "Untitled Folder": "未命名資料夾",
        // Settings
        "General": "一般",
        "Appearance": "外觀",
        "Gestures": "手勢與熱角",
        "Hidden Apps": "隱藏的 App",
        "Layout": "佈局",
        "Keyboard shortcut": "快速鍵",
        "Type a shortcut…": "請按下快速鍵…",
        "Shortcuts need ⌘, ⌃ or ⌥, or a function key.": "快速鍵需包含 ⌘、⌃ 或 ⌥，或使用功能鍵。",
        "Show icon in menu bar": "在選單列顯示圖示",
        "Open at login": "登入時打開",
        "Rows": "列數",
        "Columns": "行數",
        "Icon size": "圖示大小",
        "Background blur": "背景模糊強度",
        "Pinch with thumb and three fingers": "拇指加三指捏合",
        "Pinch in to open, spread out to close. Turn off the system gesture for Apps in System Settings › Trackpad › More Gestures to avoid conflicts.": "捏合打開、張開關閉。請在「系統設定 › 觸控板 › 更多手勢」關閉系統開啟「App」的手勢，避免衝突。",
        "Open Trackpad Settings": "打開觸控板設定",
        "Trackpad gestures are unavailable on this Mac.": "這台 Mac 無法使用觸控板手勢。",
        "Hot corner": "熱角",
        "None": "無",
        "Top Left": "左上角",
        "Top Right": "右上角",
        "Bottom Left": "左下角",
        "Bottom Right": "右下角",
        "Hidden apps stay installed; they just don’t appear in Launchpad.": "隱藏的 App 仍會保留安裝，只是不顯示在 Launchpad 中。",
        "No hidden apps.": "沒有隱藏的 App。",
        "Show": "顯示",
        "Import from this Mac": "從這台 Mac 匯入",
        "Import from a File…": "從檔案匯入…",
        "Reset to Alphabetical": "重設為字母排序",
        "Import the page and folder layout from the Launchpad of macOS 15 or earlier. To import from a Time Machine backup or an old Mac, choose its file at /private/var/folders/…/0/com.apple.dock.launchpad/db/db.": "從 macOS 15 以前的 Launchpad 匯入頁面與資料夾佈局。若要從 Time Machine 備份或舊 Mac 匯入，請選擇其 /private/var/folders/…/0/com.apple.dock.launchpad/db/db 檔案。",
        "Replace the current layout?": "要取代目前的佈局嗎？",
        "Your current pages and folders will be replaced.": "目前的頁面與資料夾將被取代。",
        "Replace": "取代",
        "Imported %d apps and %d folders.": "已匯入 %d 個 App 與 %d 個資料夾。",
        "%d apps from the old layout are no longer installed.": "舊佈局中有 %d 個 App 已不在這台 Mac 上。",
        "No old Launchpad database was found on this Mac.": "這台 Mac 上找不到舊的 Launchpad 資料庫。",
        "Import Failed": "匯入失敗",
        "Import Complete": "匯入完成",
        "Layout reset.": "已重設佈局。",
        // Folder names from App Store categories
        "Business": "商業", "Developer Tools": "開發者工具", "Education": "教育", "Entertainment": "娛樂",
        "Finance": "財經", "Games": "遊戲", "Graphics & Design": "圖形與設計", "Health & Fitness": "健康與健身",
        "Lifestyle": "生活風格", "Medical": "醫療", "Music": "音樂", "News": "新聞", "Photography": "攝影",
        "Productivity": "生產力", "Reference": "參考", "Social Networking": "社交網路", "Sports": "運動",
        "Travel": "旅遊", "Utilities": "工具程式", "Video": "影片", "Weather": "天氣",
    ]
}

func L(_ key: String) -> String {
    L10n.isChinese ? (L10n.zh[key] ?? key) : key
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

enum FolderNaming {
    static let categories: [String: String] = [
        "business": "Business", "developer-tools": "Developer Tools", "education": "Education",
        "entertainment": "Entertainment", "finance": "Finance", "graphics-design": "Graphics & Design",
        "healthcare-fitness": "Health & Fitness", "lifestyle": "Lifestyle", "medical": "Medical",
        "music": "Music", "news": "News", "photography": "Photography", "productivity": "Productivity",
        "reference": "Reference", "social-networking": "Social Networking", "sports": "Sports",
        "travel": "Travel", "utilities": "Utilities", "video": "Video", "weather": "Weather",
    ]

    /// Names a new folder after the App Store category its apps share, like the original Launchpad did.
    static func suggestedName(categories raw: [String?]) -> String {
        let names = raw.compactMap { c -> String? in
            guard let c = c?.replacingOccurrences(of: "public.app-category.", with: "") else { return nil }
            return c.hasSuffix("games") ? "Games" : categories[c]
        }
        if let first = names.first { return L(first) }
        return L("Untitled Folder")
    }
}
