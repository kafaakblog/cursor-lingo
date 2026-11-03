#include "badge_position.h"
#include "layoutfix_c.h"
#include <cstdio>
#include <cstdlib>

static void check(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

int main() {
    int cases = 0;
    for (int size : {32, 48, 64, 128, 256}) {
        // Arrow, pointing hand, and centered I-beam/crosshair hotspots.
        for (double hot : {0.0, 0.25, 0.5}) {
            lf::BadgeRect cursor = {-size * hot, -size * hot, size * (1 - hot), size * (1 - hot)};
            for (int x : {0, 10, 960, 1910, 1919}) for (int y : {0, 10, 540, 1070, 1079}) {
                lf::BadgeRect screen = {-(double)x, -(double)y, 1920.0 - x, 1080.0 - y};
                auto p = lf::placeBadge(screen, cursor, 80, 40, 6, 20);
                check(p.x >= screen.left && p.y >= screen.top && p.x + 80 <= screen.right && p.y + 40 <= screen.bottom,
                      "badge remains on screen near every edge");
                check(p.x >= cursor.right + 6 || p.x + 80 <= cursor.left - 6 ||
                      p.y >= cursor.bottom + 6 || p.y + 40 <= cursor.top - 6,
                      "badge clears enlarged arrow, hand and centered cursor");
                double s[] = {screen.left, screen.top, screen.right, screen.bottom};
                double c[] = {cursor.left, cursor.top, cursor.right, cursor.bottom}, result[2];
                lf_place_badge(s, c, 80, 40, 6, 20, result);
                check(result[0] == p.x && result[1] == p.y, "macOS bridge uses identical placement");
                ++cases;
            }
        }
    }
    auto small = lf::placeBadge({-500, -500, 500, 500}, {0, 0, 32, 32}, 80, 40, 4, 20);
    auto large = lf::placeBadge({-500, -500, 500, 500}, {0, 0, 128, 128}, 80, 40, 4, 20);
    check(large.x > small.x, "growing cursor increases clearance");
    std::printf("all badge placement tests passed (%d cursor/screen cases)\n", cases);
}
