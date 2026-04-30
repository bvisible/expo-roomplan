export enum ScanStatus {
  NotStarted = "NotStarted",
  Canceled = "Canceled",
  Error = "Error",
  OK = "OK",
}

export enum ExportType {
  Parametric = "PARAMETRIC",
  Mesh = "MESH",
  Model = "MODEL",
}

export interface UseRoomPlanParams {
  exportType?: ExportType,
  sendFileLoc?: boolean,
}

export interface ExpoRoomPlanModuleType {
  // Sync — true only on devices with LiDAR (Apple's RoomCaptureSession.isSupported).
  isSupported(): boolean;
  startCapture(scanName: string, exportType: ExportType, sendFileLoc: boolean): Promise<void>;
  stopCapture(): Promise<void>;
  presentQuickLook(filePath: string): Promise<void>;
  presentSceneViewer(
    filePath: string,
    annotations: {
      x: number;
      y: number;
      z: number;
      content: string;
      kind: string;
      photoPath?: string;
    }[]
  ): Promise<void>;
  // test
  addListener?(eventName: string, listener: (event: any) => void): { remove: () => void };
  removeListeners?(count: number): void;
}

export interface UseRoomPlanInterface {
  startRoomPlan: (scanName: string) => Promise<void>;
  roomScanStatus: ScanStatus;
  jsonUrl: string | null;
  scanUrl: string | null;
}