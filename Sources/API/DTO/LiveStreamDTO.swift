import Foundation

/// One element of the `get_live_streams` array.
public struct LiveStreamDTO: Decodable, Equatable {
    @FlexibleInt public var num: Int?
    @FlexibleString public var name: String?
    @FlexibleString public var streamType: String?
    @FlexibleInt public var streamId: Int?
    @FlexibleString public var streamIcon: String?
    @FlexibleString public var epgChannelId: String?
    @FlexibleInt public var added: Int?
    @FlexibleInt public var categoryId: Int?
    @FlexibleString public var customSid: String?
    @FlexibleInt public var tvArchive: Int?
    @FlexibleString public var directSource: String?
    @FlexibleInt public var tvArchiveDuration: Int?

    enum CodingKeys: String, CodingKey {
        case num
        case name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case added
        case categoryId = "category_id"
        case customSid = "custom_sid"
        case tvArchive = "tv_archive"
        case directSource = "direct_source"
        case tvArchiveDuration = "tv_archive_duration"
    }
}
