typedef struct foo { int x; } foo_t;

typedef int int_t;

int main() {
  foo_t x;
  int_t y;
  x.x = 12;
  return x.x + y;
}
