use eframe::egui;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone, Debug)]
struct FaultRecord {
    ts: u64,
    pid: i32,
    tid: i32,
    app: String,
    fault_type: String,
    addr: String,
    msg: String,
}

fn extract_json_str(line: &str, key: &str) -> String {
    let pattern = format!("\"{}\":\"", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let mut out = String::new();
        let mut escaped = false;
        for ch in rest.chars() {
            if escaped {
                out.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                break;
            } else {
                out.push(ch);
            }
        }
        return out;
    }
    String::new()
}

fn extract_json_u64(line: &str, key: &str) -> u64 {
    let pattern = format!("\"{}\":", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        return digits.parse::<u64>().unwrap_or(0);
    }
    0
}

fn extract_json_i32(line: &str, key: &str) -> i32 {
    let pattern = format!("\"{}\":", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let digits: String = rest
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect();
        return digits.parse::<i32>().unwrap_or(0);
    }
    0
}

struct DaemondGuiApp {
    events: Arc<Mutex<Vec<FaultRecord>>>,
    filter: String,
}

impl DaemondGuiApp {
    fn new(cc: &eframe::CreationContext<'_>, events: Arc<Mutex<Vec<FaultRecord>>>) -> Self {
        let ctx = cc.egui_ctx.clone();
        let events_bg = Arc::clone(&events);

        thread::spawn(move || {
            let child = Command::new("/home/natska/daemon-reporter-4-kernel-panics/build/daemond")
                .stdout(Stdio::piped())
                .spawn();

            if let Ok(mut proc) = child {
                if let Some(stdout) = proc.stdout.take() {
                    let reader = BufReader::new(stdout);
                    for line_res in reader.lines() {
                        if let Ok(line) = line_res {
                            if line.starts_with("{\"ts\":") {
                                let rec = FaultRecord {
                                    ts: extract_json_u64(&line, "ts"),
                                    pid: extract_json_i32(&line, "pid"),
                                    tid: extract_json_i32(&line, "tid"),
                                    app: extract_json_str(&line, "app"),
                                    fault_type: extract_json_str(&line, "type"),
                                    addr: extract_json_str(&line, "addr"),
                                    msg: extract_json_str(&line, "msg"),
                                };
                                if let Ok(mut guard) = events_bg.lock() {
                                    guard.push(rec);
                                }
                                ctx.request_repaint();
                            }
                        }
                    }
                }
            }
        });

        Self {
            events,
            filter: "ALL".to_string(),
        }
    }
}

impl eframe::App for DaemondGuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("top_bar").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("C Runtime & Kernel Panic Reporter (eGUI)");
                ui.separator();
                for f in ["ALL", "KERNEL_PANIC", "RAM_LEAK", "RACE_COND", "HARD_FAULT_OOB"] {
                    if ui.selectable_label(self.filter == f, f).clicked() {
                        self.filter = f.to_string();
                    }
                }
                if ui.button("Clear").clicked() {
                    if let Ok(mut guard) = self.events.lock() {
                        guard.clear();
                    }
                }
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            let snapshot = self
                .events
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();

            egui::ScrollArea::vertical().show(ui, |ui| {
                for ev in snapshot.iter().rev() {
                    if self.filter != "ALL" && ev.fault_type != self.filter {
                        continue;
                    }
                    let badge_color = match ev.fault_type.as_str() {
                        "KERNEL_PANIC" => egui::Color32::from_rgb(220, 38, 38),
                        "HARD_FAULT_OOB" => egui::Color32::from_rgb(234, 88, 12),
                        "RACE_COND" => egui::Color32::from_rgb(202, 138, 4),
                        "RAM_LEAK" => egui::Color32::from_rgb(37, 99, 235),
                        _ => egui::Color32::GRAY,
                    };

                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.colored_label(badge_color, format!("[{}]", ev.fault_type));
                            ui.label(format!("app={} pid={} tid={} addr={}", ev.app, ev.pid, ev.tid, ev.addr));
                            ui.label(format!("ts={}ns", ev.ts));
                        });
                        ui.label(&ev.msg);
                    });
                    ui.add_space(4.0);
                }
            });
        });
    }
}

fn main() -> eframe::Result<()> {
    let events = Arc::new(Mutex::new(Vec::new()));
    let native_options = eframe::NativeOptions::default();
    eframe::run_native(
        "daemond-egui-rust",
        native_options,
        Box::new(move |cc| Ok(Box::new(DaemondGuiApp::new(cc, events)))),
    )
}
