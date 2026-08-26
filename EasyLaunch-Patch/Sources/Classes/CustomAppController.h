#pragma once
#import "UnityAppController.h"

NS_ASSUME_NONNULL_BEGIN

/// Подкласс UnityAppController, который перехватывает initUnityWithScene:
/// и показывает PreloadViewController до старта движка Unity.
@interface CustomAppController : UnityAppController
@end

NS_ASSUME_NONNULL_END
