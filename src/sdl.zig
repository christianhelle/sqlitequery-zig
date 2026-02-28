//! Shared SDL2 C imports module.
//! Import this in any module that needs SDL2 types to avoid duplicate cImport errors.

pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
