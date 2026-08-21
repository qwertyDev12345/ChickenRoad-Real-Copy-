using System;
using UnityEngine;
namespace BrightCrossing
{
    public static class PixelArtLibrary
    {
        private static Sprite[] gameplay, environment, menuButtons;
        private static Sprite helpPanel, gotItButton, shopPanel, closeButton, notEnough;
        private static Sprite[] shopChickens;
        private static Sprite[] shopStates;
        private static Sprite[] shopNames;
        private static Sprite shopLock, shopCheck, shopSelectedFrame;
        private static Sprite gameTopHud, gameBottomHud, gameExitDialog, gameStay, gameLeave;
        private static Sprite[] gameButtons, gameMessages, gameCoins;
        public static Sprite Gameplay(int i) { gameplay ??= Slice(Resources.Load<Texture2D>("Art/PixelGameplay"), 4, 3, 100f); return i >= 0 && i < gameplay.Length ? gameplay[i] : null; }
        public static Sprite Environment(int i)
        {
            if (environment == null)
            {
                string[] names = { "Grass", "Road", "Panel", "HeaderV2", "ButtonGreen", "ButtonAmber", "ButtonBlue", "ButtonDisabled" };
                environment = new Sprite[names.Length];
                for (int n = 0; n < names.Length; n++)
                {
                    Texture2D texture = Resources.Load<Texture2D>("Art/PixelUI/" + names[n]);
                    if (!texture) continue;
                    texture.filterMode = FilterMode.Point; texture.wrapMode = TextureWrapMode.Clamp;
                    environment[n] = Sprite.Create(texture, new Rect(0, 0, texture.width, texture.height), new Vector2(.5f, .5f), 100f, 0, SpriteMeshType.FullRect);
                }
            }
            return i >= 0 && i < environment.Length ? environment[i] : null;
        }
        public static Sprite MenuButton(int i)
        {
            if (menuButtons == null)
            {
                string[] names = { "MenuPlay", "MenuDaily", "MenuShop", "MenuHelp" };
                menuButtons = new Sprite[names.Length];
                for (int n = 0; n < names.Length; n++)
                {
                    Texture2D texture = Resources.Load<Texture2D>("Art/PixelUI/" + names[n]);
                    if (!texture) continue;
                    texture.filterMode = FilterMode.Point; texture.wrapMode = TextureWrapMode.Clamp;
                    menuButtons[n] = Sprite.Create(texture, new Rect(0, 0, texture.width, texture.height), new Vector2(.5f, .5f), 100f, 0, SpriteMeshType.FullRect);
                }
            }
            return i >= 0 && i < menuButtons.Length ? menuButtons[i] : null;
        }
        public static Sprite HelpPanel() => helpPanel ??= LoadSprite("Art/PixelUI/HelpPanelTrim");
        public static Sprite GotItButton() => gotItButton ??= LoadSprite("Art/PixelUI/GotItButtonTrim");
        public static Sprite ShopPanel() => shopPanel ??= LoadSprite("Art/PixelUI/ShopPanelClean");
        public static Sprite CloseButton() => closeButton ??= LoadSprite("Art/PixelUI/CloseButtonTrim");
        public static Sprite NotEnough() => notEnough ??= LoadSprite("Art/PixelUI/NotEnoughTrim");
        public static Sprite ShopChicken(int i)
        {
            if (shopChickens == null)
            {
                string[] names = { "ShopClassic", "ShopGolden", "ShopSky", "ShopPink" };
                shopChickens = new Sprite[names.Length];
                for (int n = 0; n < names.Length; n++) shopChickens[n] = LoadSprite("Art/PixelUI/" + names[n]);
            }
            return i >= 0 && i < shopChickens.Length ? shopChickens[i] : null;
        }
        public static Sprite ShopState(int i)
        {
            if (shopStates == null)
            {
                string[] names = { "ShopBuy750", "ShopBuy500", "ShopBuy600", "ShopSelect", "ShopSelected" };
                shopStates = new Sprite[names.Length];
                for (int n = 0; n < names.Length; n++) shopStates[n] = LoadSprite("Art/PixelUI/" + names[n]);
            }
            return i >= 0 && i < shopStates.Length ? shopStates[i] : null;
        }
        public static Sprite ShopLock() => shopLock ??= LoadSprite("Art/PixelUI/ShopLock");
        public static Sprite ShopCheck() => shopCheck ??= LoadSprite("Art/PixelUI/ShopCheck");
        public static Sprite ShopSelectedFrame() => shopSelectedFrame ??= LoadSprite("Art/PixelUI/ShopSelectedFrame");
        public static Sprite ShopName(int i)
        {
            if (shopNames == null)
            {
                string[] names = { "ShopNameClassic", "ShopNameGolden", "ShopNameSky", "ShopNamePink" };
                shopNames = new Sprite[names.Length];
                for (int n = 0; n < names.Length; n++) shopNames[n] = LoadSprite("Art/PixelUI/" + names[n]);
            }
            return i >= 0 && i < shopNames.Length ? shopNames[i] : null;
        }
        public static Sprite GameTopHud() => gameTopHud ??= LoadSprite("Art/PixelUI/GameTopHud");
        public static Sprite GameBottomHud() => gameBottomHud ??= LoadSprite("Art/PixelUI/GameBottomHudV3");
        public static Sprite GameButton(int i)
        {
            if (gameButtons == null)
            {
                string[] names = { "GamePlay", "GameStep", "GameCash", "GameMenu", "GameMin", "GameMax", "GameMinus", "GamePlus", "GamePlayDisabled", "GameStepDisabled", "GameCashDisabled" };
                gameButtons = new Sprite[names.Length]; for (int n = 0; n < names.Length; n++) gameButtons[n] = LoadSprite("Art/PixelUI/" + names[n]);
            }
            return i >= 0 && i < gameButtons.Length ? gameButtons[i] : null;
        }
        public static Sprite GameMessage(int i)
        {
            if (gameMessages == null)
            {
                string[] names = { "GameMessageChoose", "GameMessageStarted", "GameMessageSafe", "GameMessageNoMoney", "GameMessageWatch", "GameMessageHit", "GameMessageWin" };
                gameMessages = new Sprite[names.Length]; for (int n = 0; n < names.Length; n++) gameMessages[n] = LoadSprite("Art/PixelUI/" + names[n]);
            }
            return i >= 0 && i < gameMessages.Length ? gameMessages[i] : null;
        }
        public static Sprite GameExitDialog() => gameExitDialog ??= LoadSprite("Art/PixelUI/GameExitDialog");
        public static Sprite GameStay() => gameStay ??= LoadSprite("Art/PixelUI/GameStay");
        public static Sprite GameLeave() => gameLeave ??= LoadSprite("Art/PixelUI/GameLeave");
        public static Sprite GameCoin(int i)
        {
            if (gameCoins == null)
            {
                gameCoins = new Sprite[10];
                for (int n = 0; n < gameCoins.Length; n++) gameCoins[n] = LoadSprite("Art/PixelUI/GameCoin" + n);
            }
            return i >= 0 && i < gameCoins.Length ? gameCoins[i] : null;
        }
        private static Sprite LoadSprite(string path)
        {
            Texture2D texture = Resources.Load<Texture2D>(path); if (!texture) return null;
            texture.filterMode = FilterMode.Point; texture.wrapMode = TextureWrapMode.Clamp;
            return Sprite.Create(texture, new Rect(0, 0, texture.width, texture.height), new Vector2(.5f, .5f), 100f, 0, SpriteMeshType.FullRect);
        }
        private static Sprite[] Slice(Texture2D texture, int columns, int rows, float ppu)
        {
            if (!texture) return Array.Empty<Sprite>(); texture.filterMode = FilterMode.Point; texture.wrapMode = TextureWrapMode.Clamp;
            var result = new Sprite[columns * rows]; float w = texture.width / (float)columns, h = texture.height / (float)rows;
            for (int row = 0; row < rows; row++) for (int col = 0; col < columns; col++) { int i = row * columns + col; result[i] = Sprite.Create(texture, new Rect(col * w, (rows - 1 - row) * h, w, h), new Vector2(.5f, .5f), ppu, 0, SpriteMeshType.Tight); }
            return result;
        }
    }
}
