#pragma once
#include <algorithm>

namespace lf {
struct BadgeRect { double left, top, right, bottom; };
struct BadgePoint { double x, y; };

// All coordinates are relative to the cursor hotspot, with Y pointing down.
// Try both sides, then below/above, keeping the badge on the current screen.
inline BadgePoint placeBadge(BadgeRect screen, BadgeRect cursor, double width, double height,
                             double gap, double preferredY) {
    const auto clampX = [&](double x) { return std::max(screen.left, std::min(x, screen.right - width)); };
    const auto clampY = [&](double y) { return std::max(screen.top, std::min(y, screen.bottom - height)); };
    BadgePoint candidates[] = {
        {cursor.right + gap, clampY(preferredY)},
        {cursor.left - gap - width, clampY(preferredY)},
        {clampX(cursor.right + gap), cursor.bottom + gap},
        {clampX(cursor.right + gap), cursor.top - gap - height},
    };
    for (auto p : candidates) {
        if (p.x >= screen.left && p.y >= screen.top && p.x + width <= screen.right && p.y + height <= screen.bottom)
            return p;
    }
    // Only possible if the screen is smaller than the cursor plus badge.
    return {clampX(candidates[0].x), clampY(candidates[0].y)};
}
} // namespace lf
