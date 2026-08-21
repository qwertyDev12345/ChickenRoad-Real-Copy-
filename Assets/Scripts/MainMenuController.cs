using System;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem.UI;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

namespace BrightCrossing
{
    public sealed class MainMenuController : MonoBehaviour
    {
        private const float DailyReward = 500f;
        private readonly Color dark = new(.055f, .075f, .09f, .97f);
        private readonly Color green = new(.22f, .84f, .38f, 1f);
        private readonly Color gold = new(1f, .68f, .12f, 1f);
        private Text balanceText, dailyText, messageText;
        private Button dailyButton;
        private RectTransform shopPanel, helpPanel, shopWarning;
        private float warningUntil;
        private Sprite chickenSprite;
        private Sprite[] skinSprites;
        private Image heroImage;
        private readonly Button[] skinButtons = new Button[4];
        private readonly Image[] skinPreviews = new Image[4];
        private readonly Image[] skinLocks = new Image[4];
        private readonly Image[] skinChecks = new Image[4];
        private readonly Image[] skinStateImages = new Image[4];
        private readonly Image[] skinCardImages = new Image[4];
        private readonly float[] skinPrices = { 0f, 750f, 500f, 600f };

        private void Awake()
        {
            Application.targetFrameRate = 60;
            GameEconomy.EnsureDefaults();
            chickenSprite = PixelArtLibrary.Gameplay(0);
            skinSprites = new[] { PixelArtLibrary.Gameplay(5), PixelArtLibrary.Gameplay(8), PixelArtLibrary.Gameplay(6), PixelArtLibrary.Gameplay(9), PixelArtLibrary.Gameplay(7), PixelArtLibrary.Gameplay(10) };
            BuildMenu();
            Refresh();
        }

        private void Update()
        {
            if (shopWarning && shopWarning.gameObject.activeSelf && Time.unscaledTime >= warningUntil) shopWarning.gameObject.SetActive(false);
            if (dailyText && GameEconomy.DailyRemaining > TimeSpan.Zero)
            {
                TimeSpan left = GameEconomy.DailyRemaining;
                dailyText.text = $"{left.Hours:00}:{left.Minutes:00}:{left.Seconds:00}";
            }
        }

        private void BuildMenu()
        {
            Camera camera = Camera.main;
            if (camera) camera.backgroundColor = new Color(.20f, .56f, .28f);
            if (!FindFirstObjectByType<EventSystem>()) new GameObject("EventSystem", typeof(EventSystem), typeof(InputSystemUIInputModule));
            var canvasObject = new GameObject("Main Menu UI", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
            var canvas = canvasObject.GetComponent<Canvas>(); canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            var scaler = canvasObject.GetComponent<CanvasScaler>(); scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize; scaler.referenceResolution = new Vector2(1920, 1080); scaler.matchWidthOrHeight = .5f;

            TexturedImage(canvas.transform, "Pixel Grass", Vector2.zero, Vector2.one, PixelArtLibrary.Environment(0), Image.Type.Tiled);
            TexturedImage(canvas.transform, "Pixel Road", new Vector2(.76f, 0), new Vector2(.91f, 1), PixelArtLibrary.Environment(1), Image.Type.Tiled);

            var header = TexturedImage(canvas.transform, "Header", new Vector2(.035f, .875f), new Vector2(.965f, .975f), PixelArtLibrary.Environment(3), Image.Type.Simple);
            header.anchorMin = header.anchorMax = new Vector2(.5f, .97f);
            header.pivot = new Vector2(.5f, 1f);
            header.sizeDelta = new Vector2(1660f, 202f);
            header.anchoredPosition = Vector2.zero;
            balanceText = Label(header, "Balance", "", 31, TextAnchor.MiddleCenter, new Vector2(.765f, .20f), new Vector2(.945f, .80f));
            balanceText.fontStyle = FontStyle.Bold; balanceText.color = new Color(.83f, .96f, 1f, 1f);
            var balanceOutline = balanceText.gameObject.AddComponent<Outline>(); balanceOutline.effectColor = new Color(.01f, .03f, .08f, 1f); balanceOutline.effectDistance = new Vector2(2f, -2f);

            var hero = new GameObject("Chicken Hero", typeof(RectTransform), typeof(Image));
            var heroRect = hero.GetComponent<RectTransform>(); heroRect.SetParent(canvas.transform, false); heroRect.anchorMin = new Vector2(.52f, .30f); heroRect.anchorMax = new Vector2(.69f, .72f); heroRect.offsetMin = heroRect.offsetMax = Vector2.zero;
            heroImage = hero.GetComponent<Image>(); heroImage.sprite = SkinPreview(GameEconomy.SelectedSkin); heroImage.preserveAspect = true;

            var content = TexturedImage(canvas.transform, "Main Card", new Vector2(.08f, .09f), new Vector2(.45f, .73f), PixelArtLibrary.Environment(2), Image.Type.Simple);
            Label(content, "Tagline", "ONE MORE STEP?", 39, TextAnchor.MiddleCenter, new Vector2(.08f, .76f), new Vector2(.92f, .89f));
            Label(content, "Subtitle", "Cross traffic. Build your multiplier.\nKnow when to stop.", 25, TextAnchor.MiddleCenter, new Vector2(.08f, .62f), new Vector2(.92f, .76f));

            ImageButton(content, "Play", PixelArtLibrary.MenuButton(0), new Vector2(.13f, .43f), new Vector2(.87f, .57f), () => SceneManager.LoadScene("ChickenRoadGame"));
            dailyButton = ImageButton(content, "Daily", PixelArtLibrary.MenuButton(1), new Vector2(.13f, .27f), new Vector2(.87f, .41f), ClaimDaily);
            dailyText = Label(dailyButton.transform, "Dynamic Status", "", 24, TextAnchor.MiddleCenter, new Vector2(.18f, .15f), new Vector2(.91f, .55f));
            dailyText.fontStyle = FontStyle.Bold; dailyText.color = new Color(.72f, .93f, 1f, 1f);
            var dailyOutline = dailyText.gameObject.AddComponent<Outline>(); dailyOutline.effectColor = new Color(.01f, .03f, .09f, 1f); dailyOutline.effectDistance = new Vector2(2f, -2f);
            ImageButton(content, "Shop", PixelArtLibrary.MenuButton(2), new Vector2(.13f, .10f), new Vector2(.48f, .23f), () => Toggle(shopPanel));
            ImageButton(content, "Help", PixelArtLibrary.MenuButton(3), new Vector2(.52f, .10f), new Vector2(.87f, .23f), () => Toggle(helpPanel));
            messageText = Label(content, "Message", "", 23, TextAnchor.MiddleCenter, new Vector2(.08f, .01f), new Vector2(.92f, .08f));

            BuildShop(canvas.transform);
            BuildHelp(canvas.transform);
        }

        private void BuildShop(Transform canvas)
        {
            shopPanel = TexturedImage(canvas, "Shop Panel", new Vector2(.47f, .08f), new Vector2(.94f, .86f), PixelArtLibrary.ShopPanel(), Image.Type.Simple);
            for (int i = 0; i < 4; i++)
            {
                int id = i;
                float left = .095f + (i % 2) * .416f;
                float bottom = i < 2 ? .528f : .096f;
                float top = i < 2 ? .891f : .497f;
                var cardObject = new GameObject("Skin " + i, typeof(RectTransform), typeof(Image), typeof(Button));
                var card = cardObject.GetComponent<RectTransform>(); card.SetParent(shopPanel, false); card.anchorMin = new Vector2(left, bottom); card.anchorMax = new Vector2(left + .394f, top); card.offsetMin = card.offsetMax = Vector2.zero;
                var hitArea = cardObject.GetComponent<Image>(); hitArea.color = new Color(1f, 1f, 1f, .001f); skinCardImages[i] = hitArea;
                var cardButton = cardObject.GetComponent<Button>(); cardButton.targetGraphic = hitArea; cardButton.onClick.AddListener(() => HandleSkinAction(id)); skinButtons[i] = cardButton;
                var cardColors = cardButton.colors; cardColors.highlightedColor = new Color(.75f, 1f, .85f, .12f); cardColors.pressedColor = new Color(.55f, .8f, .7f, .2f); cardButton.colors = cardColors;
                var preview = new GameObject("Preview", typeof(RectTransform), typeof(Image));
                var rect = preview.GetComponent<RectTransform>(); rect.SetParent(card, false); rect.anchorMin = new Vector2(.08f, .23f); rect.anchorMax = new Vector2(.92f, .82f); rect.offsetMin = rect.offsetMax = Vector2.zero;
                var image = preview.GetComponent<Image>(); image.sprite = PixelArtLibrary.ShopChicken(i); image.preserveAspect = true; image.color = Color.white; image.raycastTarget = false; skinPreviews[i] = image;

                var nameImage = OverlayImage(card, "Skin Name", new Vector2(.18f, .82f), new Vector2(.82f, .98f), PixelArtLibrary.ShopName(i));
                nameImage.preserveAspect = true; nameImage.raycastTarget = false;

                skinLocks[i] = OverlayImage(card, "Lock", new Vector2(.78f, .66f), new Vector2(.90f, .82f), PixelArtLibrary.ShopLock());
                skinLocks[i].preserveAspect = true; skinLocks[i].raycastTarget = false;
                skinChecks[i] = OverlayImage(card, "Check", new Vector2(.77f, .65f), new Vector2(.91f, .83f), PixelArtLibrary.ShopCheck());
                skinChecks[i].preserveAspect = true; skinChecks[i].raycastTarget = false;
                skinStateImages[i] = OverlayImage(card, "State", new Vector2(.08f, .025f), new Vector2(.92f, .205f), null);
                skinStateImages[i].preserveAspect = true; skinStateImages[i].raycastTarget = false;
            }
            var closeButton = ImageButton(shopPanel, "Close", PixelArtLibrary.CloseButton(), new Vector2(.35f, -.015f), new Vector2(.65f, .10f), () => Toggle(shopPanel));
            closeButton.GetComponent<Image>().preserveAspect = true;
            shopWarning = TexturedImage(shopPanel, "Not Enough Warning", new Vector2(.25f, .46f), new Vector2(.75f, .57f), PixelArtLibrary.NotEnough(), Image.Type.Simple);
            shopWarning.GetComponent<Image>().preserveAspect = true; shopWarning.gameObject.SetActive(false);
            shopPanel.gameObject.SetActive(false);
            RefreshShop();
        }

        private void BuildHelp(Transform canvas)
        {
            helpPanel = TexturedImage(canvas, "Help Panel", new Vector2(.47f, .13f), new Vector2(.95f, .83f), PixelArtLibrary.HelpPanel(), Image.Type.Simple);
            var closeButton = ImageButton(helpPanel, "Close", PixelArtLibrary.GotItButton(), new Vector2(.35f, -.01f), new Vector2(.65f, .12f), () => Toggle(helpPanel));
            closeButton.GetComponent<Image>().preserveAspect = true;
            helpPanel.gameObject.SetActive(false);
        }

        private void ClaimDaily()
        {
            if (GameEconomy.ClaimDaily(DailyReward)) messageText.text = "+500 CR DAILY BONUS CLAIMED!";
            else messageText.text = "Daily bonus is not ready yet";
            Refresh();
        }

        private void HandleSkinAction(int id)
        {
            if (!GameEconomy.OwnsSkin(id))
            {
                if (!GameEconomy.BuySkin(id, skinPrices[id])) { ShowShopWarning(); return; }
                RefreshShop();
                return;
            }
            if (GameEconomy.SelectedSkin == id) return;
            GameEconomy.SelectedSkin = id;
            RefreshShop();
        }

        private void ShowShopWarning()
        {
            shopWarning.gameObject.SetActive(true); shopWarning.SetAsLastSibling(); warningUntil = Time.unscaledTime + 2.25f;
        }

        private void RefreshShop()
        {
            int selected = GameEconomy.SelectedSkin;
            for (int i = 0; i < 4; i++)
            {
                bool owned = GameEconomy.OwnsSkin(i), isSelected = selected == i;
                if (skinPreviews[i]) skinPreviews[i].color = owned ? Color.white : new Color(.48f, .52f, .58f, .82f);
                if (skinLocks[i]) skinLocks[i].gameObject.SetActive(!owned);
                if (skinChecks[i]) skinChecks[i].gameObject.SetActive(isSelected);
                if (skinCardImages[i]) skinCardImages[i].color = new Color(1f, 1f, 1f, .001f);
                if (skinStateImages[i]) skinStateImages[i].sprite = isSelected ? PixelArtLibrary.ShopState(4) : owned ? PixelArtLibrary.ShopState(3) : PixelArtLibrary.ShopState(i - 1);
                if (skinButtons[i]) skinButtons[i].interactable = !isSelected;
            }
            if (heroImage) heroImage.sprite = SkinPreview(selected);
            Refresh();
        }

        private void Refresh()
        {
            balanceText.text = GameEconomy.LoadBalance().ToString("0.00") + " CR";
            TimeSpan left = GameEconomy.DailyRemaining;
            dailyText.text = left <= TimeSpan.Zero ? "CLAIM +500 CR" : $"{left.Hours:00}:{left.Minutes:00}:{left.Seconds:00}";
        }

        private Sprite SkinPreview(int skinId) => skinId == 0 || skinSprites == null ? chickenSprite : skinSprites[(skinId - 1) * 2];

        private static Sprite[] SliceSkinAtlas(Texture2D texture)
        {
            if (!texture) return Array.Empty<Sprite>();
            var sprites = new Sprite[6];
            float cellWidth = texture.width / 3f;
            float cellHeight = texture.height / 2f;
            for (int row = 0; row < 2; row++)
            for (int column = 0; column < 3; column++)
            {
                int index = column * 2 + row;
                sprites[index] = Sprite.Create(texture, new Rect(column * cellWidth, (1 - row) * cellHeight, cellWidth, cellHeight), new Vector2(.5f, .5f), 210f, 0, SpriteMeshType.Tight);
            }
            return sprites;
        }

        private static void Toggle(RectTransform panel) => panel.gameObject.SetActive(!panel.gameObject.activeSelf);
        private static RectTransform TexturedImage(Transform parent, string name, Vector2 min, Vector2 max, Sprite sprite, Image.Type type)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero; var image = go.GetComponent<Image>(); image.sprite = sprite; image.type = type; image.color = Color.white; image.raycastTarget = false; return rect;
        }
        private static RectTransform Panel(Transform parent, string name, Vector2 min, Vector2 max, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero; var image = go.GetComponent<Image>(); image.sprite = PixelArtLibrary.Environment(2); image.type = Image.Type.Simple; image.color = color; return rect;
        }
        private static Image OverlayImage(Transform parent, string name, Vector2 min, Vector2 max, Sprite sprite)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = sprite; image.type = Image.Type.Simple; image.color = Color.white; return image;
        }
        private static Text Label(Transform parent, string name, string value, int size, TextAnchor anchor, Vector2 min, Vector2 max)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Text)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero; var text = go.GetComponent<Text>(); text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf"); text.text = value; text.fontSize = size; text.alignment = anchor; text.color = Color.white; text.resizeTextForBestFit = true; text.resizeTextMinSize = 15; text.resizeTextMaxSize = size; return text;
        }
        private static Button Button(Transform parent, string name, string value, Vector2 min, Vector2 max, Color color, UnityEngine.Events.UnityAction action)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero; var image = go.GetComponent<Image>(); image.sprite = ButtonPixelSprite(color); image.type = Image.Type.Simple; image.color = Color.white; var button = go.GetComponent<Button>(); button.onClick.AddListener(action); Label(go.transform, "Text", value, 30, TextAnchor.MiddleCenter, Vector2.zero, Vector2.one); return button;
        }
        private static Button ImageButton(Transform parent, string name, Sprite sprite, Vector2 min, Vector2 max, UnityEngine.Events.UnityAction action)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button)); var rect = go.GetComponent<RectTransform>(); rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = rect.offsetMax = Vector2.zero;
            var image = go.GetComponent<Image>(); image.sprite = sprite; image.type = Image.Type.Simple; image.color = Color.white; image.preserveAspect = true;
            var button = go.GetComponent<Button>(); button.onClick.AddListener(action); var colors = button.colors; colors.highlightedColor = new Color(1f, 1f, 1f, .9f); colors.pressedColor = new Color(.72f, .78f, .84f, 1f); colors.disabledColor = new Color(.42f, .45f, .5f, .75f); button.colors = colors; return button;
        }
        private static Sprite ButtonPixelSprite(Color color)
        {
            if (color.g > .65f && color.r < .5f) return PixelArtLibrary.Environment(4);
            if (color.r > .7f && color.g > .35f && color.b < .4f) return PixelArtLibrary.Environment(5);
            if (color.b > .65f) return PixelArtLibrary.Environment(6);
            return PixelArtLibrary.Environment(7);
        }
    }
}
