using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class CiBuild
{
    public static void BuildIOS()
    {
        string outputPath = GetCommandLineValue("-buildOutput");
        if (string.IsNullOrWhiteSpace(outputPath))
        {
            outputPath = Environment.GetEnvironmentVariable("IOS_UNITY_OUTPUT_PATH");
        }

        if (string.IsNullOrWhiteSpace(outputPath))
        {
            outputPath = "build/iOS/iOS";
        }

        outputPath = Path.GetFullPath(outputPath);
        Directory.CreateDirectory(outputPath);

        string[] scenes = EditorBuildSettings.scenes
            .Where(scene => scene.enabled)
            .Select(scene => scene.path)
            .ToArray();

        if (scenes.Length == 0)
        {
            throw new InvalidOperationException(
                "No enabled scenes were found in Editor Build Settings.");
        }

        Debug.Log($"CI: building {scenes.Length} scene(s) for iOS into {outputPath}");

        BuildReport report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = outputPath,
            target = BuildTarget.iOS,
            options = BuildOptions.None
        });

        if (report.summary.result != BuildResult.Succeeded)
        {
            throw new InvalidOperationException(
                $"iOS build failed: {report.summary.result}; " +
                $"errors: {report.summary.totalErrors}");
        }

        Debug.Log(
            $"CI: iOS build succeeded ({report.summary.totalSize} bytes, " +
            $"{report.summary.totalTime}).");
    }

    private static string GetCommandLineValue(string key)
    {
        string[] args = Environment.GetCommandLineArgs();
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], key, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }
}
