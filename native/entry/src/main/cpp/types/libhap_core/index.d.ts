export const readModuleJson: (path: string) => string;
export const readPackInfo: (path: string) => string;
/** App icon bytes from a local HAP; empty when the package has no readable icon. */
export const readHapIcon: (path: string, iconName: string) => Uint8Array;
export const keyMatchesCertificate: (privateKeyPath: string, certificatePath: string) => boolean;
export const readSignedProfile: (profilePath: string) => string;
export const profileMatchesCertificate: (profilePath: string, certificatePath: string) => boolean;
export const verifyHap: (path: string) => Promise<void>;
export const signHap: (input: string, output: string, privateKey: string,
  certificates: string, profile: string) => Promise<void>;
export const hdcCommand: (keyRoot: string, operation: number, parameter: string) => Promise<string>;
