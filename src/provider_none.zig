//! The public build's provider: none. kowalski is a complete tracker without one.
const contract = @import("kowalski_provider");

pub fn kowalskiProvider(requested: u32) callconv(.c) ?*const contract.Table {
    _ = requested;
    return null;
}
