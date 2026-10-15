#include "drop_target.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <string>

#include "utils.h"

namespace {

UINT UrlFormat() {
  static const UINT format =
      RegisterClipboardFormatW(L"UniformResourceLocatorW");
  return format;
}

FORMATETC FormatFor(CLIPFORMAT format) {
  return {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool HasFormat(IDataObject* data, CLIPFORMAT format) {
  FORMATETC etc = FormatFor(format);
  return data->QueryGetData(&etc) == S_OK;
}

bool CanImport(IDataObject* data) {
  return HasFormat(data, CF_HDROP) ||
         HasFormat(data, static_cast<CLIPFORMAT>(UrlFormat())) ||
         HasFormat(data, CF_UNICODETEXT);
}

// Prefers copying, but browsers sometimes only offer a link effect for URLs.
DWORD EffectFor(DWORD allowed) {
  if (allowed & DROPEFFECT_COPY) return DROPEFFECT_COPY;
  if (allowed & DROPEFFECT_LINK) return DROPEFFECT_LINK;
  return DROPEFFECT_NONE;
}

std::string ReadWideText(IDataObject* data, CLIPFORMAT format) {
  FORMATETC etc = FormatFor(format);
  STGMEDIUM medium;
  if (data->GetData(&etc, &medium) != S_OK) return {};
  std::string text;
  if (auto* chars = static_cast<const wchar_t*>(GlobalLock(medium.hGlobal))) {
    size_t limit = GlobalSize(medium.hGlobal) / sizeof(wchar_t);
    text = Utf8FromUtf16(std::wstring(chars, wcsnlen(chars, limit)).c_str());
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return text;
}

flutter::EncodableList ReadDroppedFiles(IDataObject* data) {
  flutter::EncodableList paths;
  FORMATETC etc = FormatFor(CF_HDROP);
  STGMEDIUM medium;
  if (data->GetData(&etc, &medium) != S_OK) return paths;
  if (auto drop = static_cast<HDROP>(GlobalLock(medium.hGlobal))) {
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
      UINT length = DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length + 1, L'\0');
      DragQueryFileW(drop, i, path.data(), length + 1);
      path.resize(length);
      paths.emplace_back(Utf8FromUtf16(path.c_str()));
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return paths;
}

}  // namespace

DropTarget::DropTarget(flutter::BinaryMessenger* messenger, HWND window)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "memlib/drop",
          &flutter::StandardMethodCodec::GetInstance())),
      window_(window) {
  registered_ = RegisterDragDrop(window_, this) == S_OK;
}

void DropTarget::Revoke() {
  if (registered_) RevokeDragDrop(window_);
  registered_ = false;
  channel_ = nullptr;
}

HRESULT DropTarget::QueryInterface(REFIID riid, void** object) {
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG DropTarget::AddRef() { return InterlockedIncrement(&ref_count_); }

ULONG DropTarget::Release() {
  LONG count = InterlockedDecrement(&ref_count_);
  if (count == 0) delete this;
  return count;
}

HRESULT DropTarget::DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) {
  accepting_ = channel_ && CanImport(data);
  *effect = accepting_ ? EffectFor(*effect) : DROPEFFECT_NONE;
  if (accepting_) channel_->InvokeMethod("entered", nullptr);
  return S_OK;
}

HRESULT DropTarget::DragOver(DWORD, POINTL, DWORD* effect) {
  *effect = accepting_ ? EffectFor(*effect) : DROPEFFECT_NONE;
  return S_OK;
}

HRESULT DropTarget::DragLeave() {
  if (accepting_ && channel_) channel_->InvokeMethod("exited", nullptr);
  accepting_ = false;
  return S_OK;
}

HRESULT DropTarget::Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) {
  if (!accepting_ || !channel_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  accepting_ = false;
  *effect = EffectFor(*effect);
  flutter::EncodableList items = ReadDroppedFiles(data);
  if (items.empty()) {
    std::string url =
        ReadWideText(data, static_cast<CLIPFORMAT>(UrlFormat()));
    if (url.empty()) url = ReadWideText(data, CF_UNICODETEXT);
    if (!url.empty()) items.emplace_back(url);
  }
  channel_->InvokeMethod(
      "dropped", std::make_unique<flutter::EncodableValue>(std::move(items)));
  return S_OK;
}
