#include "audio_file_drop.h"
#include <shellapi.h>
#include <utility>

AudioFileDrop::AudioFileDrop(HWND window, Emit emit)
    : window_(window), emit_(std::move(emit)) {}
HRESULT AudioFileDrop::QueryInterface(REFIID iid, void** result) {
  if (!result) return E_POINTER;
  *result = nullptr;
  if (iid == IID_IUnknown || iid == IID_IDropTarget) {
    *result = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  return E_NOINTERFACE;
}
ULONG AudioFileDrop::AddRef() { return ++references_; }
ULONG AudioFileDrop::Release() {
  const auto remaining = --references_;
  if (!remaining) delete this;
  return remaining;
}
flutter::EncodableList AudioFileDrop::ReadPaths(IDataObject* data) {
  flutter::EncodableList paths;
  if (!data) return paths;
  FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium{};
  if (FAILED(data->GetData(&format, &medium))) return paths;
  const auto drop = reinterpret_cast<HDROP>(medium.hGlobal);
  const auto count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const auto length = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring wide(length + 1, L'\0');
    DragQueryFileW(drop, i, wide.data(), length + 1);
    const auto bytes = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
        static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    std::string path(bytes, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(length),
        path.data(), bytes, nullptr, nullptr);
    paths.emplace_back(path);
  }
  ReleaseStgMedium(&medium);
  return paths;
}
void AudioFileDrop::Send(const std::string& method, POINTL location) {
  POINT point{location.x, location.y};
  ScreenToClient(window_, &point);
  const auto scale = static_cast<double>(GetDpiForWindow(window_)) / 96.0;
  emit_(method, flutter::EncodableMap{
    {flutter::EncodableValue("paths"), flutter::EncodableValue(paths_)},
    {flutter::EncodableValue("x"), flutter::EncodableValue(point.x / scale)},
    {flutter::EncodableValue("y"), flutter::EncodableValue(point.y / scale)},
  });
}
HRESULT AudioFileDrop::DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  paths_ = ReadPaths(data);
  *effect = paths_.empty() ? DROPEFFECT_NONE : (*effect & DROPEFFECT_COPY);
  Send("filesEntered", point);
  return S_OK;
}
HRESULT AudioFileDrop::DragOver(DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  *effect = paths_.empty() ? DROPEFFECT_NONE : (*effect & DROPEFFECT_COPY);
  Send("filesMoved", point);
  return S_OK;
}
HRESULT AudioFileDrop::DragLeave() {
  paths_.clear();
  Send("filesExited", POINTL{});
  return S_OK;
}
HRESULT AudioFileDrop::Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) {
  if (!effect) return E_POINTER;
  paths_ = ReadPaths(data);
  *effect = paths_.empty() ? DROPEFFECT_NONE : (*effect & DROPEFFECT_COPY);
  Send("filesDropped", point);
  paths_.clear();
  return S_OK;
}
