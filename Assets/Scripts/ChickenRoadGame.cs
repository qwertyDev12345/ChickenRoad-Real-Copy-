using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem.UI;
using UnityEngine.InputSystem;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

namespace BrightCrossing
{
    public enum RoundState { Betting, Ready, Moving, Safe, CashedOut, Lost, Completed }

    public sealed class ChickenRoadGame : MonoBehaviour
    {
        [Header("Economy")]
        [SerializeField] private float startingBalance = 1000f;
        [SerializeField] private float defaultBet = 25f;
        [SerializeField] private float minBet = 5f;
        [SerializeField] private float maxBet = 250f;
        [SerializeField] private float betStep = 5f;
        [SerializeField] private float[] multipliers = { 1.10f, 1.25f, 1.45f, 1.70f, 2.05f, 2.50f, 3.10f, 4.00f, 5.50f, 8.00f };

        [Header("Gameplay")]
        [SerializeField] private float startPositionX = -5f;
        [SerializeField] private float stageSpacing = 4.2f;
        [SerializeField] private float stepDuration = .5f;
        [SerializeField] private float chickenScale = .98f;
        [SerializeField] private float vehicleBaseSpeed = 4.2f;
        [SerializeField] private float vehicleSpawnInterval = 1.35f;
        [SerializeField, Range(.03f, .3f)] private float speedIncreasePerStage = .10f;
        [SerializeField, Range(.03f, .35f)] private float trafficIncreasePerStage = .22f;
        [SerializeField] private float minimumSpawnInterval = .38f;

        private readonly List<Lane> lanes = new();
        private readonly Queue<Vehicle> vehiclePool = new();
        private readonly List<Vehicle> activeVehicles = new();
        private readonly List<SpriteRenderer> multiplierCoins = new();
        private readonly List<Button> betControlButtons = new();
        private Sprite[] art;
        private Sprite selectedIdleSprite, selectedStepSprite;
        private Transform chicken;
        private SpriteRenderer chickenRenderer;
        private Camera gameCamera;
        private Text balanceText, betText, multiplierText, winText, statusText;
        private Image statusImage;
        private Button playButton, stepButton, cashOutButton;
        private RectTransform exitConfirmationPanel;
        private float balance, bet;
        private int currentStage = -1;
        private RoundState state = RoundState.Betting;
        private bool roundFunded;
        private bool exitConfirmationOpen;

        private void Awake()
        {
            Application.targetFrameRate = 60;
            art = new[] { PixelArtLibrary.Gameplay(0), PixelArtLibrary.Gameplay(1), PixelArtLibrary.Gameplay(2), PixelArtLibrary.Gameplay(3), PixelArtLibrary.Gameplay(4) };
            ResolveSelectedChickenSprites();
            balance = GameEconomy.LoadBalance(startingBalance);
            bet = Mathf.Clamp(defaultBet, minBet, maxBet);
            BuildWorld();
            BuildUi();
            ResetRound(false);
        }

        private void Update()
        {
            UpdateTraffic();
            if (chicken && gameCamera)
            {
                Vector3 target = new(Mathf.Max(0f, chicken.position.x + 2.4f), 0f, -10f);
                gameCamera.transform.position = Vector3.Lerp(gameCamera.transform.position, target, 4f * Time.deltaTime);
            }

            var keyboard = Keyboard.current;
            if (exitConfirmationOpen)
            {
                if (keyboard != null && keyboard.escapeKey.wasPressedThisFrame) CloseExitConfirmation();
                return;
            }
            if (keyboard != null && keyboard.spaceKey.wasPressedThisFrame) TakeStep();
            if (keyboard != null && keyboard.enterKey.wasPressedThisFrame && playButton.gameObject.activeSelf) StartRound();
            if (keyboard != null && keyboard.cKey.wasPressedThisFrame) CashOut();
        }

        private void BuildWorld()
        {
            gameCamera = Camera.main;
            if (!gameCamera)
            {
                var cameraObject = new GameObject("Main Camera", typeof(Camera), typeof(AudioListener));
                gameCamera = cameraObject.GetComponent<Camera>();
                cameraObject.tag = "MainCamera";
            }
            gameCamera.orthographic = true;
            gameCamera.orthographicSize = 5.1f;
            gameCamera.backgroundColor = new Color(0.47f, 0.78f, 0.95f);
            gameCamera.transform.position = new Vector3(0f, 0f, -10f);

            float worldLeft = startPositionX - 12f;
            float worldRight = startPositionX + multipliers.Length * stageSpacing + 14f;
            float grassWidth = worldRight - worldLeft;
            CreateTexturedQuad("Grass", new Vector3((worldLeft + worldRight) * .5f, 0f, 2f), new Vector2(grassWidth, 14f), PixelArtLibrary.Environment(0), -10);
            for (int i = 0; i < multipliers.Length; i++)
            {
                // A traffic lane sits between two safe stopping points.
                float x = startPositionX + (i + .5f) * stageSpacing;
                CreateTexturedQuad("Lane " + (i + 1), new Vector3(x, 0f, 1f), new Vector2(1.6f, 11f), PixelArtLibrary.Environment(1), -5);
                float difficulty = i;
                float laneInterval = Mathf.Max(minimumSpawnInterval, vehicleSpawnInterval / (1f + difficulty * trafficIncreasePerStage));
                var lane = new Lane
                {
                    x = x,
                    stageIndex = i,
                    direction = i % 2 == 0 ? 1 : -1,
                    speed = vehicleBaseSpeed * (1f + difficulty * speedIncreasePerStage),
                    spawnInterval = laneInterval,
                    timer = UnityEngine.Random.Range(.1f, laneInterval)
                };
                lanes.Add(lane);
                CreateMultiplierCoin(i);
            }

            var chickenObject = new GameObject("Chicken", typeof(SpriteRenderer), typeof(CircleCollider2D), typeof(Rigidbody2D), typeof(ChickenHitbox));
            chicken = chickenObject.transform;
            chickenRenderer = chickenObject.GetComponent<SpriteRenderer>();
            chickenRenderer.sprite = selectedIdleSprite;
            chickenRenderer.sortingOrder = 20;
            chicken.transform.localScale = Vector3.one * chickenScale;
            var body = chickenObject.GetComponent<Rigidbody2D>();
            body.bodyType = RigidbodyType2D.Kinematic;
            body.useFullKinematicContacts = true;
            var hitbox = chickenObject.GetComponent<CircleCollider2D>();
            hitbox.isTrigger = true;
            hitbox.radius = .22f;
            hitbox.offset = new Vector2(0, -.13f);
            chickenObject.GetComponent<ChickenHitbox>().Owner = this;
        }

        private void BuildUi()
        {
            if (!FindFirstObjectByType<EventSystem>()) new GameObject("EventSystem", typeof(EventSystem), typeof(InputSystemUIInputModule));
            var canvasObject = new GameObject("Game UI", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
            var canvas = canvasObject.GetComponent<Canvas>(); canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            var scaler = canvasObject.GetComponent<CanvasScaler>(); scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize; scaler.referenceResolution = new Vector2(1920, 1080); scaler.matchWidthOrHeight = .5f;

            var top = PixelImage(canvas.transform, "Top HUD", new Vector2(.02f, .775f), new Vector2(.98f, .98f), PixelArtLibrary.GameTopHud());
            // Value labels use the exact centres of the three inset displays in GameTopHud.
            balanceText = DynamicLabel(top, "Balance Value", 32, new Vector2(.034f, .195f), new Vector2(.306f, .605f));
            multiplierText = DynamicLabel(top, "Multiplier Value", 32, new Vector2(.354f, .195f), new Vector2(.646f, .605f));
            winText = DynamicLabel(top, "Potential Value", 32, new Vector2(.674f, .195f), new Vector2(.966f, .605f));

            var bottom = PixelImage(canvas.transform, "Bottom HUD", new Vector2(.02f, .015f), new Vector2(.98f, .265f), PixelArtLibrary.GameBottomHud());
            // The four captions are baked into GameBottomHudV2. These remain as invisible
            // raycast targets, so the artwork has only one frame and cannot look misaligned.
            betControlButtons.Add(ClickArea(bottom, "Minus", new Vector2(.0295f, .490f), new Vector2(.0885f, .770f), () => ChangeBet(-betStep)));
            betControlButtons.Add(ClickArea(bottom, "Min", new Vector2(.0295f, .145f), new Vector2(.0885f, .435f), () => SetBet(minBet)));
            betText = DynamicLabel(bottom, "Bet Value", 29, new Vector2(.10f, .19f), new Vector2(.265f, .72f));
            betControlButtons.Add(ClickArea(bottom, "Plus", new Vector2(.2605f, .490f), new Vector2(.3195f, .770f), () => ChangeBet(betStep)));
            betControlButtons.Add(ClickArea(bottom, "Max", new Vector2(.2605f, .145f), new Vector2(.3195f, .435f), () => SetBet(Mathf.Min(maxBet, balance))));
            playButton = SpriteButtonCentered(bottom, "Play", PixelArtLibrary.GameButton(0), new Vector2(.4555f, .5f), new Vector2(.164f, .62f), StartRound);
            stepButton = SpriteButtonCentered(bottom, "Step", PixelArtLibrary.GameButton(1), new Vector2(.6688f, .5f), new Vector2(.164f, .62f), TakeStep);
            cashOutButton = SpriteButtonCentered(bottom, "Cash Out", PixelArtLibrary.GameButton(2), new Vector2(.8833f, .5f), new Vector2(.164f, .62f), CashOut);
            statusImage = PixelImage(canvas.transform, "Status", new Vector2(.29f, .64f), new Vector2(.71f, .76f), PixelArtLibrary.GameMessage(0)).GetComponent<Image>();
            statusImage.preserveAspect = true;
            statusText = DynamicLabel(canvas.transform, "Hidden Status", 1, Vector2.zero, Vector2.zero); statusText.gameObject.SetActive(false);
            SpriteButton(canvas.transform, "Menu", PixelArtLibrary.GameButton(3), new Vector2(.025f, .67f), new Vector2(.12f, .755f), OpenExitConfirmation);
            BuildExitConfirmation(canvas.transform);
        }

        private void StartRound()
        {
            if (state != RoundState.Betting)
            {
                ShowRequirement("Finish the current round first");
                return;
            }
            if (bet > balance || bet <= 0f)
            {
                ShowRequirement("Choose a bet within your balance");
                return;
            }
            balance -= bet;
            GameEconomy.SaveBalance(balance);
            roundFunded = true;
            currentStage = -1;
            state = RoundState.Ready;
            SetStatus(1);
            RefreshUi();
        }

        private void TakeStep()
        {
            if (state == RoundState.Betting)
            {
                ShowRequirement("Press PLAY to place your bet first");
                return;
            }
            if (state == RoundState.Moving)
            {
                ShowRequirement("Wait until the chicken lands");
                return;
            }
            if (state != RoundState.Ready && state != RoundState.Safe)
            {
                ShowRequirement("Start a new round to continue");
                return;
            }
            if (currentStage + 1 >= multipliers.Length) return;
            StartCoroutine(MoveChicken(currentStage + 1));
        }

        private IEnumerator MoveChicken(int targetStage)
        {
            state = RoundState.Moving;
            SetStatus(4);
            RefreshUi();
            Vector3 from = chicken.position;
            Vector3 to = new(startPositionX + (targetStage + 1) * stageSpacing, 0f, 0f);
            chickenRenderer.sprite = selectedStepSprite;
            float time = 0f;
            Vector3 previousPosition = from;
            while (time < stepDuration && state == RoundState.Moving)
            {
                time += Time.deltaTime;
                float t = Mathf.SmoothStep(0, 1, Mathf.Clamp01(time / stepDuration));
                chicken.position = Vector3.Lerp(from, to, t) + Vector3.up * Mathf.Sin(t * Mathf.PI) * .22f;
                if (HasVehicleOnPath(previousPosition, chicken.position))
                {
                    OnChickenHit();
                    yield break;
                }
                previousPosition = chicken.position;
                yield return null;
            }
            if (state != RoundState.Moving) yield break;
            chicken.position = to;
            chickenRenderer.sprite = selectedIdleSprite;
            currentStage = targetStage;
            HighlightMultiplierCoins();
            state = currentStage == multipliers.Length - 1 ? RoundState.Completed : RoundState.Safe;
            SetStatus(state == RoundState.Completed ? 6 : 2);
            if (state == RoundState.Completed) FinishWin();
            RefreshUi();
        }

        public void OnChickenHit()
        {
            if (state != RoundState.Moving) return;
            StopAllCoroutines();
            state = RoundState.Lost;
            chickenRenderer.color = new Color(1f, .35f, .35f);
            chicken.rotation = Quaternion.Euler(0, 0, -80f);
            SetStatus(5);
            roundFunded = false;
            Invoke(nameof(PrepareNextRound), 1.35f);
            RefreshUi();
        }

        private bool HasVehicleOnPath(Vector2 from, Vector2 to)
        {
            Physics2D.SyncTransforms();
            Vector2 delta = to - from;
            if (delta.sqrMagnitude > .000001f)
            {
                RaycastHit2D[] hits = Physics2D.CircleCastAll(from, .23f, delta.normalized, delta.magnitude);
                foreach (RaycastHit2D hit in hits)
                    if (IsVehicle(hit.collider)) return true;
            }

            Collider2D[] overlaps = Physics2D.OverlapCircleAll(to, .24f);
            foreach (Collider2D overlap in overlaps)
                if (IsVehicle(overlap)) return true;

            // Test the relative swept paths of both moving objects. Unlike a normal cast,
            // this cannot miss a vehicle that crosses the chicken entirely between frames.
            foreach (Vehicle vehicle in activeVehicles)
            {
                Vector2 relativeStart = from - vehicle.previousPosition;
                Vector2 relativeEnd = to - (Vector2)vehicle.transform.position;
                Vector3 scale = vehicle.transform.lossyScale;
                Vector2 halfExtents = Vector2.Scale(vehicle.collider.size, new Vector2(Mathf.Abs(scale.x), Mathf.Abs(scale.y))) * .5f;
                halfExtents += Vector2.one * .24f;
                if (SegmentIntersectsAabb(relativeStart, relativeEnd, halfExtents)) return true;
            }
            return false;
        }

        private static bool SegmentIntersectsAabb(Vector2 start, Vector2 end, Vector2 halfExtents)
        {
            Vector2 direction = end - start;
            float enter = 0f;
            float exit = 1f;
            for (int axis = 0; axis < 2; axis++)
            {
                float origin = axis == 0 ? start.x : start.y;
                float delta = axis == 0 ? direction.x : direction.y;
                float extent = axis == 0 ? halfExtents.x : halfExtents.y;
                if (Mathf.Abs(delta) < .000001f)
                {
                    if (origin < -extent || origin > extent) return false;
                    continue;
                }
                float first = (-extent - origin) / delta;
                float second = (extent - origin) / delta;
                if (first > second) (first, second) = (second, first);
                enter = Mathf.Max(enter, first);
                exit = Mathf.Min(exit, second);
                if (enter > exit) return false;
            }
            return exit >= 0f && enter <= 1f;
        }

        private static bool IsVehicle(Collider2D candidate) => candidate && candidate.gameObject.name.StartsWith("Vehicle", StringComparison.Ordinal);

        private void CashOut()
        {
            if (state == RoundState.Betting)
            {
                ShowRequirement("Press PLAY and cross at least one road first");
                return;
            }
            if (state == RoundState.Ready || currentStage < 0)
            {
                ShowRequirement("Cross one road before cashing out");
                return;
            }
            if (state == RoundState.Moving)
            {
                ShowRequirement("Wait until the chicken reaches safety");
                return;
            }
            if (state != RoundState.Safe)
            {
                ShowRequirement("Cash out is unavailable in this state");
                return;
            }
            state = RoundState.CashedOut;
            float payout = bet * multipliers[currentStage];
            balance += payout;
            GameEconomy.SaveBalance(balance);
            roundFunded = false;
            SetStatus(6);
            RefreshUi();
            Invoke(nameof(PrepareNextRound), 1.15f);
        }

        private void FinishWin()
        {
            float payout = bet * multipliers[^1];
            balance += payout;
            GameEconomy.SaveBalance(balance);
            roundFunded = false;
            SetStatus(6);
            Invoke(nameof(PrepareNextRound), 1.4f);
        }

        private void PrepareNextRound() => ResetRound(false);

        private void ResetRound(bool refund)
        {
            CancelInvoke();
            StopAllCoroutines();
            if (refund && roundFunded) balance += bet;
            roundFunded = false;
            currentStage = -1;
            HighlightMultiplierCoins();
            state = RoundState.Betting;
            chicken.position = new Vector3(startPositionX, 0f, 0f);
            chicken.rotation = Quaternion.identity;
            chickenRenderer.color = Color.white;
            chickenRenderer.sprite = selectedIdleSprite;
            SetStatus(0);
            RefreshUi();
        }

        private void ChangeBet(float delta) => SetBet(bet + delta);
        private void OpenExitConfirmation()
        {
            if (exitConfirmationOpen) return;
            exitConfirmationOpen = true;
            exitConfirmationPanel.gameObject.SetActive(true);
        }

        private void CloseExitConfirmation()
        {
            exitConfirmationOpen = false;
            exitConfirmationPanel.gameObject.SetActive(false);
        }

        private void ConfirmReturnToMenu()
        {
            roundFunded = false;
            GameEconomy.SaveBalance(balance);
            SceneManager.LoadScene("MainMenu");
        }

        private void BuildExitConfirmation(Transform canvas)
        {
            exitConfirmationPanel = Panel(canvas, "Exit Confirmation Overlay", Vector2.zero, Vector2.one, new Color(0f, 0f, 0f, .76f));
            var blocker = exitConfirmationPanel.gameObject.AddComponent<CanvasGroup>();
            blocker.blocksRaycasts = true;
            var dialog = PixelImage(exitConfirmationPanel, "Dialog", new Vector2(.19f, .28f), new Vector2(.81f, .72f), PixelArtLibrary.GameExitDialog());
            SpriteButton(exitConfirmationPanel, "Stay", PixelArtLibrary.GameStay(), new Vector2(.285f, .16f), new Vector2(.475f, .30f), CloseExitConfirmation);
            SpriteButton(exitConfirmationPanel, "Leave", PixelArtLibrary.GameLeave(), new Vector2(.525f, .16f), new Vector2(.715f, .30f), ConfirmReturnToMenu);
            exitConfirmationPanel.gameObject.SetActive(false);
        }
        private void SetBet(float value)
        {
            if (state != RoundState.Betting)
            {
                ShowRequirement("You cannot change the bet during an active round");
                return;
            }
            bet = Mathf.Clamp(value, minBet, Mathf.Min(maxBet, Mathf.Max(minBet, balance)));
            RefreshUi();
        }

        private void ShowRequirement(string message)
        {
            if (message.IndexOf("balance", StringComparison.OrdinalIgnoreCase) >= 0)
                SetStatus(3);
            else if (state == RoundState.Moving || message.IndexOf("wait", StringComparison.OrdinalIgnoreCase) >= 0)
                SetStatus(4);
            else
                SetStatus(state == RoundState.Safe ? 2 : 0);
            CancelInvoke(nameof(RestoreStateMessage));
            Invoke(nameof(RestoreStateMessage), 1.8f);
        }

        private void RestoreStateMessage()
        {
            SetStatus(state switch
            {
                RoundState.Betting => 0,
                RoundState.Ready => 1,
                RoundState.Moving => 4,
                RoundState.Safe => 2,
                RoundState.Lost => 5,
                _ => 6
            });
        }

        private void RefreshUi()
        {
            balanceText.text = Money(balance);
            betText.text = Money(bet);
            multiplierText.text = currentStage >= 0 ? multipliers[currentStage].ToString("0.00") + "×" : "—";
            winText.text = currentStage >= 0 ? Money(bet * multipliers[currentStage]) : "—";
            bool canPlay = state == RoundState.Betting && bet <= balance;
            bool canStep = state == RoundState.Ready || state == RoundState.Safe;
            bool canCashOut = state == RoundState.Safe && currentStage >= 0;
            SetButtonAvailability(playButton, canPlay);
            SetButtonAvailability(stepButton, canStep);
            SetButtonAvailability(cashOutButton, canCashOut);
            foreach (Button betButton in betControlButtons)
                SetButtonAvailability(betButton, state == RoundState.Betting);
        }

        private void SetButtonAvailability(Button button, bool available)
        {
            button.interactable = true; // Keep clicks enabled so unavailable actions can explain their requirements.
            Image image = button.GetComponent<Image>();
            if (button == playButton)
            {
                image.color = Color.white;
                image.sprite = PixelArtLibrary.GameButton(available ? 0 : 8);
            }
            else if (button == stepButton)
            {
                image.color = Color.white;
                image.sprite = PixelArtLibrary.GameButton(available ? 1 : 9);
            }
            else if (button == cashOutButton)
            {
                image.color = Color.white;
                image.sprite = PixelArtLibrary.GameButton(available ? 2 : 10);
            }
            else
            {
                // Bet controls are transparent raycast areas over captions baked into the HUD.
                image.color = new Color(1f, 1f, 1f, .001f);
            }
        }

        private void UpdateTraffic()
        {
            if (lanes.Count == 0) return;
            for (int i = 0; i < lanes.Count; i++)
            {
                Lane lane = lanes[i];
                lane.timer -= Time.deltaTime;
                if (lane.timer <= 0f)
                {
                    SpawnVehicle(lane, i);
                    lane.timer = lane.spawnInterval * UnityEngine.Random.Range(.78f, 1.18f);
                }
            }
            for (int i = activeVehicles.Count - 1; i >= 0; i--)
            {
                Vehicle vehicle = activeVehicles[i];
                vehicle.previousPosition = vehicle.transform.position;
                vehicle.transform.position += Vector3.up * (vehicle.speed * vehicle.direction * Time.deltaTime);
                if (Mathf.Abs(vehicle.transform.position.y) > 7.5f) Despawn(vehicle, i);
            }
        }

        private void SpawnVehicle(Lane lane, int laneIndex)
        {
            Vehicle vehicle;
            if (vehiclePool.Count > 0) vehicle = vehiclePool.Dequeue();
            else
            {
                var go = new GameObject("Vehicle", typeof(SpriteRenderer), typeof(BoxCollider2D), typeof(Rigidbody2D));
                vehicle = new Vehicle { transform = go.transform, renderer = go.GetComponent<SpriteRenderer>(), collider = go.GetComponent<BoxCollider2D>() };
                var rigidbody = go.GetComponent<Rigidbody2D>(); rigidbody.bodyType = RigidbodyType2D.Kinematic; rigidbody.collisionDetectionMode = CollisionDetectionMode2D.Continuous;
                vehicle.collider.isTrigger = true;
            }
            vehicle.transform.gameObject.SetActive(true);
            vehicle.transform.position = new Vector3(lane.x, lane.direction > 0 ? -6.4f : 6.4f, 0f);
            vehicle.previousPosition = vehicle.transform.position;
            vehicle.transform.localScale = Vector3.one * UnityEngine.Random.Range(.8f, 1.05f);
            // Later roads favour longer vehicles, reducing the safe crossing window.
            float largeVehicleChance = Mathf.Lerp(.28f, .72f, lane.stageIndex / Mathf.Max(1f, multipliers.Length - 1f));
            int vehicleType;
            if (UnityEngine.Random.value < largeVehicleChance)
                vehicleType = UnityEngine.Random.value < .52f ? 1 : 2;
            else
                vehicleType = 0;
            vehicle.renderer.sprite = GetArt(2 + vehicleType);
            vehicle.renderer.sortingOrder = 10;
            float[] vehicleLengths = { 1.42f, 2.05f, 2.38f };
            float[] vehicleWidths = { .66f, .72f, .76f };
            vehicle.collider.size = new Vector2(vehicleWidths[vehicleType], vehicleLengths[vehicleType]);
            vehicle.speed = lane.speed * UnityEngine.Random.Range(.88f, 1.14f);
            vehicle.direction = lane.direction;
            ApplyVehicleOrientation(vehicle);
            activeVehicles.Add(vehicle);
        }

        private static void ApplyVehicleOrientation(Vehicle vehicle)
        {
            // All top-down vehicle sprites are authored with their front facing down.
            // A negative Y velocity therefore uses the source orientation; positive Y rotates 180°.
            float signedVelocityY = vehicle.speed * vehicle.direction;
            vehicle.transform.rotation = Quaternion.Euler(0f, 0f, signedVelocityY > 0f ? 180f : 0f);
        }

        private void Despawn(Vehicle vehicle, int index)
        {
            activeVehicles.RemoveAt(index);
            vehicle.transform.gameObject.SetActive(false);
            vehiclePool.Enqueue(vehicle);
        }

        private Sprite GetArt(int index) => art != null && index >= 0 && index < art.Length ? art[index] : null;
        private void ResolveSelectedChickenSprites()
        {
            selectedIdleSprite = GetArt(0);
            selectedStepSprite = GetArt(1) ? GetArt(1) : selectedIdleSprite;
            int skin = GameEconomy.SelectedSkin;
            if (skin <= 0) return;
            int column = Mathf.Clamp(skin - 1, 0, 2);
            selectedIdleSprite = PixelArtLibrary.Gameplay(5 + column);
            selectedStepSprite = PixelArtLibrary.Gameplay(8 + column);
        }
        private static Sprite[] SliceAtlas(Texture2D texture)
        {
            if (!texture) return Array.Empty<Sprite>();
            var sprites = new Sprite[8];
            float cellWidth = texture.width / 4f;
            float cellHeight = texture.height / 2f;
            for (int row = 0; row < 2; row++)
            for (int column = 0; column < 4; column++)
            {
                int index = row * 4 + column;
                var rect = new Rect(column * cellWidth, (1 - row) * cellHeight, cellWidth, cellHeight);
                // Vehicle artwork is not perfectly centred inside its generated atlas cells.
                // A content-aware pivot keeps the visible roof aligned with the physics body and road centre.
                float pivotX = index switch { 2 => .40f, 3 => .31f, 4 => .60f, _ => .5f };
                sprites[index] = Sprite.Create(texture, rect, new Vector2(pivotX, .5f), 180f, 0, SpriteMeshType.Tight);
                sprites[index].name = "GeneratedSprite_" + index;
            }
            return sprites;
        }
        private string Money(float value) => value.ToString("0.00") + " CR";

        private GameObject CreateQuad(string name, Vector3 position, Vector2 size, Color color, int order)
        {
            var go = new GameObject(name, typeof(SpriteRenderer));
            go.transform.position = position;
            go.transform.localScale = new Vector3(size.x, size.y, 1);
            var renderer = go.GetComponent<SpriteRenderer>();
            renderer.sprite = RuntimeSprite.White;
            renderer.color = color;
            renderer.sortingOrder = order;
            return go;
        }

        private GameObject CreateTexturedQuad(string name, Vector3 position, Vector2 size, Sprite sprite, int order)
        {
            var go = new GameObject(name, typeof(SpriteRenderer)); go.transform.position = position;
            var renderer = go.GetComponent<SpriteRenderer>(); renderer.sprite = sprite; renderer.drawMode = SpriteDrawMode.Tiled; renderer.size = size; renderer.sortingOrder = order; return go;
        }

        private void CreateMultiplierCoin(int stageIndex)
        {
            float x = startPositionX + (stageIndex + 1) * stageSpacing;
            var coin = new GameObject("Multiplier Coin " + (stageIndex + 1), typeof(SpriteRenderer));
            coin.transform.position = new Vector3(x, .45f, 0f);
            coin.transform.localScale = Vector3.one * .72f;
            var renderer = coin.GetComponent<SpriteRenderer>();
            renderer.sprite = PixelArtLibrary.GameCoin(stageIndex);
            renderer.color = Color.white;
            renderer.sortingOrder = 14;
            multiplierCoins.Add(renderer);
        }

        private void HighlightMultiplierCoins()
        {
            for (int i = 0; i < multiplierCoins.Count; i++)
            {
                if (i < currentStage) multiplierCoins[i].color = new Color(.55f, .72f, .34f, 1f);
                else multiplierCoins[i].color = Color.white;
                multiplierCoins[i].transform.localScale = Vector3.one * (i == currentStage ? .83f : .72f);
            }
        }

        private static RectTransform Panel(Transform parent, string name, Vector2 min, Vector2 max, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = PixelArtLibrary.Environment(3); image.type = Image.Type.Sliced; image.color = color;
            return rect;
        }

        private static Text Label(Transform parent, string name, string text, int size, TextAnchor alignment, Vector2 min, Vector2 max)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Text));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var label = go.GetComponent<Text>();
            label.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf"); label.text = text; label.fontSize = size; label.alignment = alignment; label.color = Color.white;
            label.resizeTextForBestFit = true; label.resizeTextMinSize = 15; label.resizeTextMaxSize = size;
            return label;
        }

        private static RectTransform PixelImage(Transform parent, string name, Vector2 min, Vector2 max, Sprite sprite)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image)); var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = sprite; image.type = Image.Type.Simple; image.color = Color.white; image.raycastTarget = false; return rect;
        }

        private static Text DynamicLabel(Transform parent, string name, int size, Vector2 min, Vector2 max)
        {
            Text text = Label(parent, name, string.Empty, size, TextAnchor.MiddleCenter, min, max); text.fontStyle = FontStyle.Bold; text.color = new Color(.85f, .97f, 1f, 1f);
            var outline = text.gameObject.AddComponent<Outline>(); outline.effectColor = new Color(.01f, .025f, .07f, 1f); outline.effectDistance = new Vector2(2f, -2f); return text;
        }

        private static Button SpriteButton(Transform parent, string name, Sprite sprite, Vector2 min, Vector2 max, UnityEngine.Events.UnityAction action)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button)); var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = sprite; image.type = Image.Type.Simple; image.preserveAspect = true; image.color = Color.white;
            var button = go.GetComponent<Button>(); button.onClick.AddListener(action); var colors = button.colors; colors.highlightedColor = new Color(1f, 1f, 1f, .88f); colors.pressedColor = new Color(.7f, .76f, .82f, 1f); button.colors = colors; return button;
        }

        private static Button SpriteButtonCentered(Transform parent, string name, Sprite sprite, Vector2 center, Vector2 size, UnityEngine.Events.UnityAction action)
        {
            Vector2 half = size * .5f;
            return SpriteButton(parent, name, sprite, center - half, center + half, action);
        }

        private static Button ClickArea(Transform parent, string name, Vector2 min, Vector2 max, UnityEngine.Events.UnityAction action)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button));
            var rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = RuntimeSprite.White; image.color = new Color(1f, 1f, 1f, .001f);
            var button = go.GetComponent<Button>(); button.transition = Selectable.Transition.None; button.onClick.AddListener(action);
            return button;
        }

        private void SetStatus(int index)
        {
            if (statusImage) statusImage.sprite = PixelArtLibrary.GameMessage(Mathf.Clamp(index, 0, 6));
        }


        private sealed class Lane { public float x, speed, timer, spawnInterval; public int direction, stageIndex; }
        private sealed class Vehicle { public Transform transform; public SpriteRenderer renderer; public BoxCollider2D collider; public Vector2 previousPosition; public float speed; public int direction; }
    }

    public sealed class ChickenHitbox : MonoBehaviour
    {
        public ChickenRoadGame Owner { get; set; }
        private void OnTriggerEnter2D(Collider2D other) { if (other.name.StartsWith("Vehicle", StringComparison.Ordinal)) Owner?.OnChickenHit(); }
        private void OnTriggerStay2D(Collider2D other) { if (other.name.StartsWith("Vehicle", StringComparison.Ordinal)) Owner?.OnChickenHit(); }
    }

    internal static class RuntimeSprite
    {
        private static Sprite white;
        private static Sprite circle;
        public static Sprite White
        {
            get
            {
                if (white) return white;
                var texture = new Texture2D(1, 1); texture.name = "Runtime White"; texture.SetPixel(0, 0, Color.white); texture.Apply();
                white = Sprite.Create(texture, new Rect(0, 0, 1, 1), new Vector2(.5f, .5f), 1f);
                return white;
            }
        }

        public static Sprite Circle
        {
            get
            {
                if (circle) return circle;
                const int size = 96;
                var texture = new Texture2D(size, size, TextureFormat.RGBA32, false) { name = "Runtime Circle" };
                var pixels = new Color32[size * size];
                Vector2 center = Vector2.one * (size - 1) * .5f;
                float radius = size * .48f;
                for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    float distance = Vector2.Distance(new Vector2(x, y), center);
                    byte alpha = (byte)Mathf.Clamp(Mathf.RoundToInt((radius - distance + 1f) * 255f), 0, 255);
                    pixels[y * size + x] = new Color32(255, 255, 255, alpha);
                }
                texture.SetPixels32(pixels); texture.Apply();
                circle = Sprite.Create(texture, new Rect(0, 0, size, size), new Vector2(.5f, .5f), size);
                return circle;
            }
        }
    }
}
