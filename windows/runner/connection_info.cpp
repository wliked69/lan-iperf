#include <winsock2.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <wlanapi.h>
#include <vector>
#include <cstdio>
#include <cstring>
#include "network_discovery.h"
#include "utils.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
void Put(Map& row, const char* key, double value) {
  if (value > 0) row[Value(key)] = Value(value);
}
void ReadWifi(HANDLE handle, const GUID& guid, Map& row) {
  DWORD size = 0;
  void* data = nullptr;
  const DWORD status = WlanQueryInterface(handle, &guid,
      wlan_intf_opcode_current_connection, nullptr, &size, &data, nullptr);
  if (status == ERROR_SUCCESS && data && size >= sizeof(WLAN_CONNECTION_ATTRIBUTES)) {
    const auto& attributes = *static_cast<WLAN_CONNECTION_ATTRIBUTES*>(data);
    const auto& link = attributes.wlanAssociationAttributes;
    Put(row, "rxMbps", link.ulRxRate / 1000.0);
    Put(row, "txMbps", link.ulTxRate / 1000.0);
    row[Value("signalPercent")] = Value(static_cast<int32_t>(link.wlanSignalQuality));
    const char* standard = nullptr;
    switch (link.dot11PhyType) {
      case dot11_phy_type_ht: standard = "Wi-Fi 4 (802.11n)"; break;
      case dot11_phy_type_vht: standard = "Wi-Fi 5 (802.11ac)"; break;
      case dot11_phy_type_he: standard = "Wi-Fi 6 (802.11ax)"; break;
      case dot11_phy_type_eht: standard = "Wi-Fi 7 (802.11be)"; break;
      case dot11_phy_type_ofdm: standard = "802.11a"; break;
      case dot11_phy_type_hrdsss: standard = "802.11b"; break;
      case dot11_phy_type_erp: standard = "802.11g"; break;
      default: break;
    }
    if (standard) row[Value("standard")] = Value(standard);
    // Read only cached BSS entries; do not initiate a wireless scan.
    WLAN_BSS_LIST* bss = nullptr;
    if (WlanGetNetworkBssList(handle, &guid, nullptr, dot11_BSS_type_any,
        FALSE, nullptr, &bss) == ERROR_SUCCESS && bss) {
      for (DWORD i = 0; i < bss->dwNumberOfItems; ++i) {
        const auto& entry = bss->wlanBssEntries[i];
        if (memcmp(entry.dot11Bssid, link.dot11Bssid, sizeof(DOT11_MAC_ADDRESS)) == 0) {
          Put(row, "frequencyMHz", entry.ulChCenterFrequency / 1000.0);
          row[Value("rssi")] = Value(static_cast<int32_t>(entry.lRssi));
          break;
        }
      }
      WlanFreeMemory(bss);
    }
  } else if (status == ERROR_ACCESS_DENIED) {
    row[Value("note")] = Value("Wi-Fi 详情受系统限制，请在 Windows 设置中允许位置访问。");
  } else {
    row[Value("note")] = Value("无线驱动未提供完整连接详情。");
  }
  if (data) WlanFreeMemory(data);
  data = nullptr;
  if (WlanQueryInterface(handle, &guid, wlan_intf_opcode_channel_number,
      nullptr, &size, &data, nullptr) == ERROR_SUCCESS && data && size >= sizeof(ULONG)) {
    row[Value("channel")] = Value(static_cast<int32_t>(*static_cast<ULONG*>(data)));
  }
  if (data) WlanFreeMemory(data);
  data = nullptr;
  if (WlanQueryInterface(handle, &guid, wlan_intf_opcode_rssi,
      nullptr, &size, &data, nullptr) == ERROR_SUCCESS && data && size >= sizeof(LONG)) {
    const LONG rssi = *static_cast<LONG*>(data);
    if (rssi < 0 && rssi > -127) row[Value("rssi")] = Value(static_cast<int32_t>(rssi));
  }
  if (data) WlanFreeMemory(data);
}
}

flutter::EncodableList ReadConnectionInfo(uint32_t* error) {
  ULONG size = 15000, status = ERROR_BUFFER_OVERFLOW;
  std::vector<unsigned char> buffer;
  IP_ADAPTER_ADDRESSES* adapters = nullptr;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW; ++attempt) {
    buffer.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER |
        GAA_FLAG_INCLUDE_GATEWAYS, nullptr, adapters, &size);
  }
  flutter::EncodableList rows;
  *error = status == ERROR_NO_DATA ? ERROR_SUCCESS : status;
  if (status != ERROR_SUCCESS) return rows;
  HANDLE wlan = nullptr;
  DWORD version = 0;
  WlanOpenHandle(2, nullptr, &version, &wlan);
  for (auto adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
    const bool wifi = adapter->IfType == IF_TYPE_IEEE80211;
    Map row{
      {Value("name"), Value(adapter->FriendlyName ? Utf8FromUtf16(adapter->FriendlyName) : adapter->AdapterName)},
      {Value("type"), Value(wifi ? "wifi" : adapter->IfType == IF_TYPE_ETHERNET_CSMACD ? "ethernet" : "other")},
      {Value("preferred"), Value(adapter->FirstGatewayAddress != nullptr)},
    };
    // NDIS reports negotiated link speeds in bits/s, not measured throughput.
    if (adapter->TransmitLinkSpeed != ~0ULL) Put(row, "txMbps", adapter->TransmitLinkSpeed / 1000000.0);
    if (adapter->ReceiveLinkSpeed != ~0ULL) Put(row, "rxMbps", adapter->ReceiveLinkSpeed / 1000000.0);
    for (auto address = adapter->FirstUnicastAddress; address; address = address->Next) {
      if (!address->Address.lpSockaddr || address->Address.lpSockaddr->sa_family != AF_INET) continue;
      const auto ip = reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);
      const auto bytes = reinterpret_cast<const unsigned char*>(&ip->sin_addr);
      char text[16];
      snprintf(text, sizeof(text), "%u.%u.%u.%u", static_cast<unsigned>(bytes[0]),
          static_cast<unsigned>(bytes[1]), static_cast<unsigned>(bytes[2]), static_cast<unsigned>(bytes[3]));
      row[Value("address")] = Value(text);
      break;
    }
    if (wifi) {
      GUID guid{};
      if (wlan && ConvertInterfaceLuidToGuid(&adapter->Luid, &guid) == NO_ERROR) ReadWifi(wlan, guid, row);
      else row[Value("note")] = Value("无法读取无线服务详情，链路速率以网卡报告为准。");
    }
    rows.emplace_back(row);
  }
  if (wlan) WlanCloseHandle(wlan, nullptr);
  return rows;
}
