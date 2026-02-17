// Server-Sent Events client for live log streaming

type SSECallback = (data: string) => void;

export class SSEClient {
  private eventSource: EventSource | null = null;
  private url: string;
  private onMessage: SSECallback;
  private onError?: () => void;

  constructor(url: string, onMessage: SSECallback, onError?: () => void) {
    this.url = url;
    this.onMessage = onMessage;
    this.onError = onError;
  }

  connect(): void {
    this.close();
    this.eventSource = new EventSource(this.url);
    this.eventSource.onmessage = (e) => {
      this.onMessage(e.data);
    };
    this.eventSource.onerror = () => {
      if (this.onError) this.onError();
    };
  }

  close(): void {
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
  }

  isConnected(): boolean {
    return this.eventSource?.readyState === EventSource.OPEN;
  }
}
