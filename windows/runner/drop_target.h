#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <ole2.h>
#include <windows.h>

#include <memory>

// Accepts dropped files, links and text on |window| and forwards them to Dart
// over the "memlib/drop" channel as a list of strings: file paths for real
// files, otherwise the dropped URL or text for Dart to interpret.
class DropTarget : public IDropTarget {
 public:
  DropTarget(flutter::BinaryMessenger* messenger, HWND window);

  // Unregisters from the window. The object stays alive until OLE releases it.
  void Revoke();

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override;

 private:
  virtual ~DropTarget() = default;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  LONG ref_count_ = 1;
  bool registered_ = false;
  bool accepting_ = false;
};

#endif  // RUNNER_DROP_TARGET_H_
