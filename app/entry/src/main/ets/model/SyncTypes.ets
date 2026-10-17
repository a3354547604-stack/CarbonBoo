/**
 * SyncTypes —— 多设备同步与近场协同的界面态类型。
 *
 * 职责：定义对端设备 `DevicePeer` 与会话状态 `SyncSessionState`（协同页 18.1/18.3 直接绑定）。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §5.3 + §6。
 * 口径（ADR-0001）：服务端云端同步是主通路；鸿蒙分布式降级为**近场演示层**。
 * 铁律 1 例外（**五类**）：登录/注册、多设备同步、商品取价、云端备份、配置下发（`GET /api/v1/config`，
 * 免鉴权、与取价同组；失败降级为内置种子）可依赖网络，其余全部离线可用；取价/配置取不到即用内置值，
 * 故例外只影响数据新鲜度、不影响可用性。
 */
export interface DevicePeer {
  deviceId: string;
  deviceName: string;
  deviceModel?: string;
  networkId: string;
  online: boolean;
  lastSeenAt?: number;
}

export interface SyncSessionState {
  phase: 'idle' | 'discovering' | 'merging' | 'writingBack' | 'done' | 'failed';
  progress: number;
  pulledCount: number;
  pushedCount: number;
  conflictCount: number;
  peerDevice?: string;
  startedAt?: number;
  finishedAt?: number;
  errorMsg?: string;
}
