export const readModuleJson: (path: string) => string;
export const readPackInfo: (path: string) => string;
/** JSON permission list, including a validated embedded QuietStart worker. */
export const readInstallPermissions: (path: string) => string;
/** Structural check only; cryptographic verification is separate. */
export const hasSigningBlock: (path: string) => boolean;
/** App icon bytes from a local HAP; empty when the package has no readable icon. */
export const readHapIcon: (path: string, iconName: string) => Uint8Array;
export const keyMatchesCertificate: (privateKeyPath: string, certificatePath: string) => boolean;
export const certificateFingerprint: (certificatePath: string) => string;
/** Build a P-256 PKCS#10 CSR from the same PKCS#8 PEM used for HAP signing. */
export const generateCsr: (privateKeyPem: string) => string;
export const readSignedProfile: (profilePath: string) => string;
export const profileMatchesCertificate: (profilePath: string, certificatePath: string) => boolean;
export const verifyHap: (path: string) => Promise<void>;
export const signHap: (input: string, output: string, privateKey: string,
  certificates: string, profile: string) => Promise<void>;
export const hdcCommand: (keyRoot: string, operation: number, parameter: string) => Promise<string>;
export const hdcInstallProgress: (path: string, reset?: boolean) => string;
/** 断开所有设备调试链路，返回断开数量。失败按 0 处理。 */
export const hdcDisconnect: () => number;
