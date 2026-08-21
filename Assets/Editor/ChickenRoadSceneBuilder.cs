using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace BrightCrossing.Editor
{
    public static class ChickenRoadSceneBuilder
    {
        [MenuItem("Chicken Road/Build Game Scene")]
        public static void Build()
        {
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            var cameraObject = new GameObject("Main Camera", typeof(Camera), typeof(AudioListener));
            cameraObject.tag = "MainCamera";
            cameraObject.transform.position = new Vector3(0, 0, -10);
            cameraObject.GetComponent<Camera>().orthographic = true;
            cameraObject.GetComponent<Camera>().orthographicSize = 5.1f;
            new GameObject("Chicken Road Game", typeof(ChickenRoadGame));
            Directory.CreateDirectory("Assets/Scenes");
            EditorSceneManager.SaveScene(scene, "Assets/Scenes/ChickenRoadGame.unity");
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene("Assets/Scenes/ChickenRoadGame.unity", true) };
            AssetDatabase.SaveAssets();
            Debug.Log("Chicken Road game scene built successfully.");
        }

        public static void BuildBatch()
        {
            Build();
            EditorApplication.Exit(0);
        }
    }
}
