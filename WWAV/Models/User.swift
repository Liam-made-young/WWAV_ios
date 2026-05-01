import Foundation

struct UserProfile: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var remoteUserId: Int?
    var name: String
    var handle: String
    var bio: String
    var profilePicture: String?
}
