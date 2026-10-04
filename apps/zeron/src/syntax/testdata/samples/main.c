#include <stdio.h>
#define MAX(a, b) ((a) > (b) ? (a) : (b))
/* block comment */
typedef struct Point { int x, y; } Point;
static const char *names[] = { "a", "b\n", NULL };
enum Color { RED, GREEN = 2 };
int main(int argc, char **argv) {
    Point p = { .x = 1, .y = 2 };
    for (size_t i = 0; i < 10u; ++i) { printf("%d %f\n", MAX(p.x, p.y), 1.5); }
    if (argc > 1 && argv[1][0] == 'x') return -1;
    goto done;
done:
    return sizeof(Point);
}
