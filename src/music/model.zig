//! What the TUI shows from Apple Music: one flat item type for songs, albums, artists,
//! playlists and stations, catalog or library, plus pages and titled groups of them.
const std = @import("std");

pub const Kind = enum { song, album, artist, playlist, station, music_video, curator };

pub const Artwork = struct {
    /// A template with `{w}` and `{h}`, or a plain URL (generated library playlist art).
    url: []const u8,
    /// The largest size available.
    width: ?u32 = null,
    height: ?u32 = null,
    /// Colors as 0xRRGGBB. Library resources have none.
    bg: ?u24 = null,
    text1: ?u24 = null,
};

pub const Item = struct {
    kind: Kind,
    /// The id to navigate and play with: the library id (`i.`, `l.`, `r.`, `p.`) for library items.
    id: []const u8,
    /// The catalog id. Equal to `id` for catalog items; null for library items with no catalog
    /// match (uploads, private playlists).
    catalog_id: ?[]const u8 = null,
    library: bool = false,
    title: []const u8,
    /// artistName, curatorName, or a station's provider.
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    track_number: ?u16 = null,
    disc_number: ?u16 = null,
    track_count: ?u32 = null,
    release_date: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    /// editorialNotes or description (short when there is one), as plain text.
    description: ?[]const u8 = null,
    artwork: ?Artwork = null,
    explicit: bool = false,
    /// From `extend=inFavorites`; null when Apple did not say.
    favorited: ?bool = null,
    /// Live radio (Apple Music 1 and others).
    is_live: bool = false,
    /// Has playParams.
    playable: bool = true,
    /// A library playlist tagged "favorited": the Favorite Songs playlist.
    tags_favorited: bool = false,
    /// A library playlist the user can add tracks to.
    can_edit: bool = false,
};

pub const Page = struct {
    items: []Item,
    /// The offset of the next page; null on the last one.
    next_offset: ?u32 = null,
    /// How many there are in all, when Apple says (library collections and library tracks).
    total: ?u32 = null,
};

/// A titled section: a recommendation, a chart, a search result type, an artist view.
pub const Group = struct {
    title: []const u8,
    items: []Item,
    next_offset: ?u32 = null,
    /// What the section is, for paging it: a search type (`songs`, `library-albums`), an artist
    /// view (`top-songs`), a chart's orderId, a recommendation id; `""` when there is nothing to page.
    key: []const u8 = "",
};
