//! Studio Script Console eval handler (labelle-scripting#4) — the
//! engine-coupled HOOK SHIM over the plugin's tested eval core.
//!
//! ## How this file reaches a game (why it can import the engine)
//!
//! This file is NOT part of the `labelle_scripting` module and never
//! compiles inside this repo (whose tests link only the Script Runtime
//! Contract + mock world). It ships in the plugin's bundled
//! `scripting_console` pack (plugin.labelle `.packs`, Asset-Plugins
//! Phase 2): at generate time the assembler copies the pack, scans this
//! `hooks/` file, and folds `*<pack module>.hooks.console_eval.ConsoleEval`
//! into the generated game's `GameHooks` receiver tuple (Packs RFC §4).
//! Pack modules import `labelle-engine` and every decl-module plugin —
//! including this plugin as `scripting` — which is exactly the surface
//! the shim needs and the game-side registration the ticket calls
//! "comptime hook registration".
//!
//! ## The channel
//!
//! Declaring `engine__editor_plugin_command` here subscribes the game to
//! the engine's editor-plugin-command broadcast
//! (`engine.Events.editor_plugin_command`, dispatched synchronously by
//! `Game.editorPluginCommand[Out]` — labelle-engine#748). Both feeders
//! route through it: the studio bridge (`editor_plugin_command_out`,
//! bridge v1.8) and scripts' `labelle_plugin_call` (script contract
//! v1.2). Handlers name-filter themselves: anything that isn't
//! `plugin == "scripting" && command == "eval"` returns untouched, so
//! other plugins' panels never see a stray response (respond is
//! single-shot, first-writer-wins).
//!
//! ## Cost + compatibility gates
//!
//! Per-frame cost is zero — the handler only runs when a command is
//! dispatched (a studio action or a script plugin-call, never the tick
//! path). Compatibility:
//!   - the event decl (`Events.editor_plugin_command`) must exist on the
//!     resolved engine or `MergeHooks` rejects the handler name at
//!     compile time — i.e. the pack needs labelle-engine ≥ the #748
//!     release (v2.4+; every engine the scripting plugin itself supports
//!     already has it);
//!   - the RESPONSE channel (`engine.plugin_command`, labelle-engine#758,
//!     v2.5.0) is `@hasDecl`-gated below: on an engine that has the event
//!     but predates responses, the shim degrades to the ticket's original
//!     behavior — the response JSON goes to the script log through the
//!     contract's `labelle_log` — and nothing else changes.

const std = @import("std");
const engine = @import("labelle-engine");
const scripting = @import("scripting");

/// Does this engine ship the #758 response channel?
const has_respond = @hasDecl(engine, "plugin_command");

/// Response buffer size: the engine channel's own cap when it exists
/// (handlers writing more are truncated by the channel — pre-bounding at
/// the same number means they never are), else the plugin's mirror.
const response_cap = if (has_respond)
    engine.plugin_command.max_response_len
else
    scripting.eval.max_response_len;

pub const ConsoleEval = struct {
    pub fn engine__editor_plugin_command(_: *ConsoleEval, info: anytype) void {
        // Name-filter (the channel is a broadcast): not ours → not a peep.
        if (!std.mem.eql(u8, info.plugin, "scripting")) return;
        if (!std.mem.eql(u8, info.command, "eval")) return;

        // The whole eval path — params decode, VM eval in the persistent
        // console env, error isolation, bounded response JSON — is the
        // plugin core (tested against the mock world in the plugin repo).
        var buf: [response_cap]u8 = undefined;
        const response = scripting.handleEvalCommand(info.params, &buf);

        if (comptime has_respond) {
            // Single-shot response for the command being dispatched
            // (first-writer-wins; a refusal just means another handler
            // answered first — the channel already warned).
            _ = engine.plugin_command.respond(response);
        } else {
            // Pre-#758 engine: no response channel — results go to the
            // script log (the console UX handles the absence gracefully).
            scripting.contract.labelle_log(response.ptr, response.len);
        }
    }
};
