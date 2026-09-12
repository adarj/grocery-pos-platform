#include "kiosk_mode.h"

#include <cstdlib>
#include <cstring>

bool grocery_pos_kiosk_value_enabled(const char* value) {
  return value != nullptr && std::strcmp(value, "1") == 0;
}

bool grocery_pos_kiosk_enabled() {
  return grocery_pos_kiosk_value_enabled(std::getenv("GROCERY_POS_KIOSK"));
}
