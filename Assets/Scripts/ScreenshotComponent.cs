using System.Collections;
using UnityEngine;
using UnityEngine.InputSystem;

public class ScreenshotComponent : MonoBehaviour
{
    void Update()
    {
        if (Keyboard.current != null && Keyboard.current.pKey.wasPressedThisFrame)
        {
            StartCoroutine(TakeScreenShot());
        }
    }
    IEnumerator TakeScreenShot()
    {
        yield return new WaitForEndOfFrame();
        string currentTime = System.DateTime.Now.ToString("MM-dd-yy (HH-mm-ss)");
        ScreenCapture.CaptureScreenshot("screenshot " + currentTime + ".png");
        Debug.Log("A screenshot was taken!");
    }
}
