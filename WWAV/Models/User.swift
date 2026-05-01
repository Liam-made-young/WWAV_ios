import Foundation

struct UserProfile: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var name: String
    var handle: String
    var bio: String
}
