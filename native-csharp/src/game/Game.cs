// Placeholder game module — REPLACED AT GENERATE.
//
// In a consuming game, the assembler stages the project's `csharp/` dir over
// this directory (`native-csharp/src/game/`), so the game's `Game.cs` is this
// module's real body. The convention it must implement is exactly one static
// method on a class named `Game` (global namespace — no `using` needed, the
// script API types are global; see Labelle.cs):
//
//     public static class Game {
//         public static void Register(Scripts scripts) {
//             scripts.Add("player", new Player());
//         }
//     }
//
// This placeholder keeps the shipped assembly compiling standalone
// (`dotnet build` in the plugin repo, and the repo's own test recomposition) —
// it registers nothing.

/// <summary>The game registration entry point (the placeholder — registers no
/// scripts). Replaced by the game's own <c>Game.cs</c> at generate.</summary>
public static class Game
{
    public static void Register(Scripts scripts)
    {
        _ = scripts;
    }
}
