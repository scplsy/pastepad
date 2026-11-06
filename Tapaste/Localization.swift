import Foundation

func L(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}
