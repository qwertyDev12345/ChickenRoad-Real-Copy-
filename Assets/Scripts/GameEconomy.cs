using System;
using UnityEngine;

namespace BrightCrossing
{
    public static class GameEconomy
    {
        private const string BalanceKey = "BrightCrossing.Balance";
        private const string DailyKey = "BrightCrossing.LastDailyUtc";
        private const string SkinKey = "BrightCrossing.SelectedSkin";

        public static float LoadBalance(float fallback = 1000f) => PlayerPrefs.GetFloat(BalanceKey, fallback);

        public static void SaveBalance(float value)
        {
            PlayerPrefs.SetFloat(BalanceKey, Mathf.Max(0f, value));
            PlayerPrefs.Save();
        }

        public static TimeSpan DailyRemaining
        {
            get
            {
                string raw = PlayerPrefs.GetString(DailyKey, string.Empty);
                if (!long.TryParse(raw, out long ticks)) return TimeSpan.Zero;
                TimeSpan remaining = TimeSpan.FromHours(24) - (DateTime.UtcNow - new DateTime(ticks, DateTimeKind.Utc));
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }

        public static bool ClaimDaily(float reward)
        {
            if (DailyRemaining > TimeSpan.Zero) return false;
            SaveBalance(LoadBalance() + reward);
            PlayerPrefs.SetString(DailyKey, DateTime.UtcNow.Ticks.ToString());
            PlayerPrefs.Save();
            return true;
        }

        public static bool OwnsSkin(int id) => id == 0 || PlayerPrefs.GetInt("BrightCrossing.Skin." + id, 0) == 1;

        public static bool BuySkin(int id, float price)
        {
            if (OwnsSkin(id)) return true;
            float balance = LoadBalance();
            if (balance < price) return false;
            SaveBalance(balance - price);
            PlayerPrefs.SetInt("BrightCrossing.Skin." + id, 1);
            PlayerPrefs.Save();
            return true;
        }

        public static void EnsureDefaults()
        {
            if (!PlayerPrefs.HasKey("BrightCrossing.Skin.0")) PlayerPrefs.SetInt("BrightCrossing.Skin.0", 1);
            if (!PlayerPrefs.HasKey(SkinKey)) PlayerPrefs.SetInt(SkinKey, 0);
            PlayerPrefs.Save();
        }

        public static int SelectedSkin
        {
            get
            {
                int id = PlayerPrefs.GetInt(SkinKey, 0);
                return OwnsSkin(id) ? id : 0;
            }
            set { if (OwnsSkin(value)) { PlayerPrefs.SetInt(SkinKey, value); PlayerPrefs.Save(); } }
        }

    }
}
