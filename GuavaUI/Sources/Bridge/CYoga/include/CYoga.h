#pragma once
// Umbrella header: re-exports the Yoga C API for Swift consumption.
// Include paths resolve via the yoga SPM package's publicHeadersPath ("."),
// so headers are accessible as <yoga/XXX.h> from the checkout root.
#include <yoga/YGConfig.h>
#include <yoga/YGEnums.h>
#include <yoga/YGMacros.h>
#include <yoga/YGNode.h>
#include <yoga/YGNodeLayout.h>
#include <yoga/YGNodeStyle.h>
#include <yoga/YGPixelGrid.h>
#include <yoga/YGValue.h>
#include <yoga/Yoga.h>
