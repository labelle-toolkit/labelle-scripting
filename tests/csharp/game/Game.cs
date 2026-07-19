// The csharp suite's test game module (labelle-engine#743): the
// `Game.Register` convention entry point, recomposed into the test assembly
// in place of native-csharp/src/game/Game.cs's placeholder (see
// tests/csharp/LabelleScriptsTest.csproj). Registers the scenario scripts the
// Zig suite (tests/csharp_suite.zig) drives and asserts against the mock world.
//
// Registration order is hook order: `spawner` registers FIRST (its Init seeds
// the world before the system's, its Update runs before the system's), and
// Deinit runs in REVERSE registration order — so the system tears down first.

// (Script API types are global — see native-csharp/src/Labelle.cs.)

public static class Game
{
    public static void Register(Scripts scripts)
    {
        scripts.Add("spawner", new Spawner());
        scripts.Add("hunger", new HungerSystem());
        // Bulk component access (contract v1.3, #44): registers LAST so
        // its entities never shift the spawner's (entity 1); see
        // BulkProbe.cs for the token matrix tests/csharp_suite.zig pins.
        scripts.Add("bulk", new BulkProbe());
    }
}
