#ifndef LAN_NETWORK_DISCOVERY_H_
#define LAN_NETWORK_DISCOVERY_H_
#include <flutter/encodable_value.h>
#include <cstdint>
flutter::EncodableList ReadLocalNetworks(uint32_t* error);
flutter::EncodableList ReadConnectionInfo(uint32_t* error);
#endif
