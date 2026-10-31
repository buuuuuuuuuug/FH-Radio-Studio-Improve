#ifndef RUNNER_AUDIO_FILE_DROP_H_
#define RUNNER_AUDIO_FILE_DROP_H_
#include <windows.h>
#include <ole2.h>
#include <oleidl.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <string>

// OLE supplies hover/leave notifications; WM_DROPFILES remains a fallback.
class AudioFileDrop final : public IDropTarget {
 public:
  using Emit = std::function<void(const std::string&, flutter::EncodableMap)>;
  AudioFileDrop(HWND coordinate_window, Emit emit);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject*, DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD*) override;
 private:
  flutter::EncodableList ReadPaths(IDataObject* data);
  void Send(const std::string& method, POINTL point);
  HWND window_;
  Emit emit_;
  ULONG references_ = 1;
  flutter::EncodableList paths_;
};
#endif
