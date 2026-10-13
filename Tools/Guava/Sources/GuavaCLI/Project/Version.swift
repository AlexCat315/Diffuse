import Foundation

struct ApplicationVersion: Codable, Equatable {
    var name = "0.1.0"
    var build = 1
    enum CodingKeys: CodingKey { case name, build }
    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? name
        build = try values.decodeIfPresent(Int.self, forKey: .build) ?? build
    }
    func validate() throws {
        guard name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              (1...2_100_000_000).contains(build) else {
            throw ToolError.invalid("version requires a numeric major.minor.patch name and a positive build number")
        }
    }
}
