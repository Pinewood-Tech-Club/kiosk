import { ZXING_LIBRARY_JS, ZXING_VERSION } from "./zxing-lib";
import { ZXING_WASM_BASE64 } from "./zxing-wasm";

export const ZXING_WASM_PATH = `/giftcard/zxing-reader-${ZXING_VERSION}.wasm`;

const worker = `
const OPTIONS = {
  formats: ["QRCode", "DataMatrix", "Aztec", "PDF417", "Code128", "Code39", "Code93", "Codabar", "ITF"],
  tryHarder: true, tryRotate: true, tryInvert: true, tryDownscale: true, maxNumberOfSymbols: 1,
};
const ready = ZXingWASM.prepareZXingModule({ overrides: { locateFile: () => ${JSON.stringify(ZXING_WASM_PATH)} }, fireImmediately: true });
ready.then(() => postMessage({ ready: true }), () => postMessage({ ready: false }));
onmessage = async (e) => {
  let texts = [];
  const { id, data, width, height } = e.data;
  try { texts = (await ZXingWASM.readBarcodes({ data, width, height }, OPTIONS)).map((r) => r.text); } catch (err) {}
  postMessage({ id, texts });
};
`;

export const SCAN_WORKER_JS = ZXING_LIBRARY_JS + "\n" + worker;

let wasm: Uint8Array | null = null;
export function zxingWasm(): Uint8Array {
  return (wasm ??= Uint8Array.from(atob(ZXING_WASM_BASE64), (c) => c.charCodeAt(0)));
}
