#include <winsock2.h>
#include <iphlpapi.h>
#include <ws2tcpip.h>
#include <vector>
#include <cstdio>
#include "network_discovery.h"
#include "utils.h"

flutter::EncodableList ReadLocalNetworks(uint32_t* error) {
  ULONG size = 15000;
  ULONG status = ERROR_BUFFER_OVERFLOW;
  std::vector<unsigned char> buffer;
  IP_ADAPTER_ADDRESSES* adapters = nullptr;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW; ++attempt) {
    buffer.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_INET,
      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_INCLUDE_GATEWAYS,
      nullptr, adapters, &size);
  }
  flutter::EncodableList networks;
  *error = status == ERROR_NO_DATA ? ERROR_SUCCESS : status;
  if (status != ERROR_SUCCESS) return networks;
  for (auto adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
    for (auto address = adapter->FirstUnicastAddress; address; address = address->Next) {
      if (!address->Address.lpSockaddr || address->Address.lpSockaddr->sa_family != AF_INET) continue;
      const auto ipv4 = reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);
      char text[INET_ADDRSTRLEN] = {};
      // Formatting directly avoids requiring WSAStartup merely to enumerate adapters.
      const auto bytes = reinterpret_cast<const unsigned char*>(&ipv4->sin_addr);
      snprintf(text, sizeof(text), "%u.%u.%u.%u", static_cast<unsigned>(bytes[0]),
        static_cast<unsigned>(bytes[1]), static_cast<unsigned>(bytes[2]), static_cast<unsigned>(bytes[3]));
      const std::string name = adapter->FriendlyName ? Utf8FromUtf16(adapter->FriendlyName) : adapter->AdapterName;
      networks.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
        {flutter::EncodableValue("address"), flutter::EncodableValue(std::string(text))},
        {flutter::EncodableValue("prefix"), flutter::EncodableValue(static_cast<int32_t>(address->OnLinkPrefixLength))},
        {flutter::EncodableValue("preferred"), flutter::EncodableValue(adapter->FirstGatewayAddress != nullptr)}});
    }
  }
  return networks;
}
