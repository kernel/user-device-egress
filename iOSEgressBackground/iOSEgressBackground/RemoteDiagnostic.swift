import Foundation

enum RemoteDiagnostic {
    // A bounded VM-side CDP client prevents Kernel standby independently of the
    // phone. Its heartbeat measures the observer, never iOS task progress.
    static let observerCode = """
    const fs=require('node:fs');
    const marker='/tmp/kernel-egress-observer.json';
    const ws=new WebSocket(process.env.EGRESS_DIAGNOSTIC_CDP);
    let nextID=1, pending, connected=false;
    const stop=code=>process.exit(code);
    setTimeout(()=>stop(0),450000);
    setTimeout(()=>{if(!connected) stop(1);},10000);
    ws.onerror=()=>stop(1); ws.onclose=()=>stop(0);
    ws.onopen=()=>{
      const tick=()=>{
        if(pending) return;
        pending=nextID++;
        ws.send(JSON.stringify({id:pending,method:'Browser.getVersion'}));
      };
      tick(); setInterval(tick,2000);
    };
    ws.onmessage=event=>{
      const reply=JSON.parse(event.data);
      if(reply.error) return stop(1);
      if(pending && reply.id===pending){
        pending=undefined; connected=true;
        fs.writeFileSync(marker+'.tmp',JSON.stringify({heartbeat:Date.now()}),{mode:0o600});
        fs.renameSync(marker+'.tmp',marker);
      }
    };
    """

    // This loop lives in the cloud page, not in the phone. It keeps measuring
    // attempted requests even if iOS suspends the phone's polling loop.
    static func startCode(runID: String, plan: DiagnosticPlan) throws -> String {
        guard UUID(uuidString: runID) != nil else { throw DemoError("Invalid diagnostic ID.") }
        return """
        await page.goto('https://checkip.amazonaws.com/?bootstrap=\(runID)', {waitUntil:'domcontentloaded',timeout:25000});
        return await page.evaluate(() => {
          if (window.__egressDiagnostic) throw new Error('Diagnostic already started');
          const state = window.__egressDiagnostic = {runID:'\(runID)',done:false,samples:[]};
          const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
          const deadline = Date.now() + 420000;
          void (async () => {
            try {
              for (let index=0; index<\(plan.count) && Date.now()<deadline; index++) {
                if (index===\(plan.gapAfter) && \(plan.gapSeconds)>0) await sleep(\(plan.gapSeconds * 1000));
                if (Date.now()>=deadline) break;
                const started=Date.now(), controller=new AbortController();
                const timer=setTimeout(()=>controller.abort(),8000);
                let ip=null,error=null;
                try {
                  const response=await fetch('/?run=\(runID)&sample='+index+'&t='+started, {cache:'no-store',signal:controller.signal});
                  const body=(await response.text()).trim();
                  if (!response.ok || !/^[0-9a-fA-F:.]{3,45}$/.test(body)) throw new Error('InvalidIPResponse');
                  ip=body;
                } catch(e) { error=e.name || 'RequestFailed'; }
                finally { clearTimeout(timer); }
                state.samples.push({index,started,finished:Date.now(),ip,error});
                if(index+1<\(plan.count)) await sleep(5000);
              }
            } finally { state.done=true; }
          })();
          return {runID:state.runID, now:Date.now(),done:state.done,samples:[...state.samples]};
        });
        """
    }

    static let pollCode = """
    const fs=await import('node:fs');
    let observerHeartbeat=null;
    try { observerHeartbeat=JSON.parse(fs.readFileSync('/tmp/kernel-egress-observer.json','utf8')).heartbeat; }
    catch(e) { if(e.code!=='ENOENT') throw e; }
    const probe=await page.evaluate(() => {
      const s=window.__egressDiagnostic;
      if(!s) throw new Error('Diagnostic state missing');
      return {runID:s.runID,now:Date.now(),done:s.done,samples:[...s.samples]};
    });
    return {...probe,observerHeartbeat};
    """
}

extension KernelAPI {
    func startDiagnosticObserver(browser: KernelBrowser) async throws {
        guard let endpoint = browser.cdp_ws_url, URL(string: endpoint)?.scheme == "wss" else {
            throw DemoError("Kernel did not return a secure observer endpoint.")
        }
        struct Body: Encodable {
            let command = "node"
            let args = ["-e", RemoteDiagnostic.observerCode]
            let env: [String: String]
            let timeout_sec = 460
        }
        // The only credential sent into this disposable VM is its own CDP URL.
        // Never send the Kernel API key, log the URL, or persist it in a report.
        _ = try await request("POST", "/browsers/\(browser.session_id)/process/spawn",
                              body: JSONEncoder().encode(Body(env: ["EGRESS_DIAGNOSTIC_CDP": endpoint])))
    }

    func diagnostic(browserID: String, code: String) async throws -> CloudProbe {
        struct Body: Encodable { let code: String; let timeout_sec = 30 }
        struct Reply: Decodable { let success: Bool; let result: CloudProbe? }
        let data = try await request("POST", "/browsers/\(browserID)/playwright/execute", body: JSONEncoder().encode(Body(code: code)))
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success, let probe = reply.result else { throw DemoError("Cloud diagnostic could not run.") }
        return probe
    }
}
