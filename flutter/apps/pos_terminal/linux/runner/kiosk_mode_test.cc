#include "kiosk_mode.h"

#include <cassert>

int main() {
  assert(!grocery_pos_kiosk_value_enabled(nullptr));
  assert(!grocery_pos_kiosk_value_enabled(""));
  assert(!grocery_pos_kiosk_value_enabled("0"));
  assert(!grocery_pos_kiosk_value_enabled("true"));
  assert(grocery_pos_kiosk_value_enabled("1"));
  return 0;
}
