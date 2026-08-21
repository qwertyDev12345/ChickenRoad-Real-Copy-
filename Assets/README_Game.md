# Bright Crossing — Game Scene

Open `Assets/Scenes/MainMenu.unity` and press Play. The menu provides Play, a +500 CR daily bonus, a persistent balance, a cosmetic chicken shop, and How to Play instructions.

The shop uses three separate generated character designs with matching idle and step poses: Golden Explorer, Sky Pilot, and Pink Rockstar. These are distinct sprites, not color overlays.

The current interface uses the restrained `PixelEnvironmentUIV2.png` set: low-noise teal grass, a narrow road, thin-bordered panels, and consistent flat pixel buttons.

Controls: UI buttons, `Enter` to start a round, `Space` to step right, and `C` to cash out. All amounts are virtual `CR` points; the project contains no real-money payments.

Rebuild the scene through `Chicken Road > Build Game Scene`. Multipliers, balance, bet limits, vehicle speed, and spawn intervals are configurable on the `ChickenRoadGame` component.

Vehicles use the original `Assets/Resources/Art/ArcadeSpritesTopDownV6.png` atlas. The car, truck, and bus use a strict orthographic top-down view. The binary alpha channel keeps the background transparent and game objects fully opaque.

Difficulty increases on every road: vehicles become faster, spawn intervals decrease, and long trucks and buses appear more often. Tune the progression through `Speed Increase Per Stage`, `Traffic Increase Per Stage`, and `Minimum Spawn Interval`.
