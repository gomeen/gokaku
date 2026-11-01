//! Self-authored isolated JSONL adapter. No macOS host or installed-user paths.
use qingjian_core::{Candidate, Engine, Query, emoji::EmojiTable, shuangpin::Scheme};
use qingjian_dictionary::{Dictionary, WordList};
use qingjian_lm::BigramModel;
use serde_json::{Value, json};
use std::{env, error::Error, fs, io::{self, BufRead, Write}, path::PathBuf, time::Instant};

const VERSION: &str = "379139671d191a5c9dc21972a54e15bc1edd9e17";

struct Worker {
    engine: Engine,
    visible: Vec<Candidate>,
}

impl Worker {
    fn select(&mut self, index: usize) -> Result<String, &'static str> {
        let candidate = self.visible.get(index).ok_or("candidate index outside visible top ten")?.clone();
        Ok(self.engine.commit(&candidate))
    }

    fn respond(&mut self, request: &Value) -> Value {
        let started = Instant::now();
        let mut commit = String::new();
        let mut handled = true;
        let operation: Result<(), &str> = match request.get("op").and_then(Value::as_str) {
            Some("reset") => {
                self.engine.clear();
                self.engine.break_chain();
                self.engine.enter_input_box();
                self.visible.clear();
                Ok(())
            }
            Some("peek") => Ok(()),
            Some("select") => match request.get("index").and_then(Value::as_u64) {
                Some(index) if index < 10 => self.select(index as usize).map(|text| commit = text),
                _ => Err("index must be an integer from 0 to 9"),
            },
            Some("key") => match request.get("key").and_then(Value::as_u64) {
                Some(8) => { handled = self.engine.backspace(); Ok(()) }
                Some(27) => {
                    handled = !self.engine.composition().is_empty() || !self.engine.held_text().is_empty();
                    self.engine.clear();
                    Ok(())
                }
                Some(32) => {
                    if !self.visible.is_empty() {
                        self.select(0).map(|text| commit = text)
                    } else if !self.engine.composition().is_empty() || !self.engine.held_text().is_empty() {
                        commit = self.engine.take_raw();
                        Ok(())
                    } else { handled = false; Ok(()) }
                }
                Some(13) => {
                    handled = !self.engine.composition().is_empty() || !self.engine.held_text().is_empty();
                    if handled { commit = self.engine.take_raw(); }
                    Ok(())
                }
                Some(key @ (97..=122 | 39)) => { self.engine.push(char::from(key as u8)); Ok(()) }
                _ => Err("unsupported key: lowercase ASCII, apostrophe, Backspace, Escape, Space, Return only"),
            },
            _ => Err("unknown or missing op"),
        };
        if operation.is_err() { handled = false; }
        // Same eager query API used by the macOS host. Sorting is in query().
        // Keep all query work in process_ns and all top-ten enumeration, copying
        // and marked-text/state extraction in collect_ns. Never stop the timer
        // before materializing candidates.
        let query: Result<Query, _> = self.engine.query();
        let process_ns = started.elapsed().as_nanos() as u64;
        let collecting = Instant::now();
        let preedit = match query {
            Ok(query) => {
                let marked = query.marked_text();
                self.visible = query.candidates.items.into_iter().take(10).collect();
                marked
            }
            // Incomplete/invalid pinyin can be a normal intermediate state.
            Err(_) => {
                self.visible.clear();
                format!("{}{}", self.engine.held_text(), self.engine.composition().text())
            }
        };
        let candidates: Vec<String> = self.visible.iter().map(|c| c.text.clone()).collect();
        let raw_input = self.engine.composition().text().to_owned();
        let held = self.engine.held_text();
        let composing = !raw_input.is_empty() || !held.is_empty();
        let collect_ns = collecting.elapsed().as_nanos() as u64;
        let total_ns = started.elapsed().as_nanos() as u64;
        let mut response = json!({
            "ok":operation.is_ok(), "handled":handled, "preedit":preedit,
            "raw_input":raw_input, "candidates":candidates, "commit":commit,
            "composing":composing, "process_ns":process_ns,
            "collect_ns":collect_ns, "total_ns":total_ns,
            "held":held,
        });
        if let Err(error) = operation { response["error"] = json!(error); }
        response
    }
}

fn layout_check(path: &str) -> Result<Value, Box<dyn Error>> {
    let cases: Value = serde_json::from_slice(&fs::read(path)?)?;
    let mut mismatches = Vec::new();
    let mut checked = 0;
    for case in cases["cases"].as_array().ok_or("cases missing")? {
        let mut encoded = String::new();
        for syllable in case["pinyin"].as_str().ok_or("pinyin missing")?.split_whitespace() {
            let pair = Scheme::Xiaohe.encode(syllable).ok_or("unencodable syllable")?;
            encoded.extend(pair);
            checked += 1;
        }
        if encoded != case["keys"].as_str().ok_or("keys missing")? {
            mismatches.push(json!({"id":case["id"],"frozen":case["keys"],"core":encoded}));
        }
    }
    let mut examples = serde_json::Map::new();
    for syllable in ["xia", "xiang", "a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "er"] {
        examples.insert(syllable.into(), json!(Scheme::Xiaohe.encode(syllable).map(|s| s.into_iter().collect::<String>())));
    }
    Ok(json!({"cases":cases["cases"].as_array().unwrap().len(), "syllables_checked":checked,
        "mismatches":mismatches, "examples":examples}))
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().collect();
    if args.get(1).is_some_and(|a| a == "--check-layout") {
        println!("{}", layout_check(args.get(2).ok_or("missing cases path")?)?);
        return Ok(());
    }
    let root = args.get(1).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp/gogaku-ime-benchmark/qingjian"));
    let started = Instant::now();
    let data = root.join("data/generated");
    let source = root.join("source");
    let dictionary = Dictionary::from_path(data.join("dict.qj"))?;
    let dictionary_entries = dictionary.len();
    let mut general = Dictionary::from_path(data.join("dicts/general.qj"))?;
    general.set_secondary(true); // same default as platform::extra_dictionaries::load
    let idioms = Dictionary::from_path(data.join("dicts/idioms.qj"))?;
    let extras = json!({"general":{"entries":general.len(),"secondary":true},"idioms":{"entries":idioms.len()}});
    let model = BigramModel::from_path(&data.join("lm.qj"))?;
    let model_info = json!({"words":model.word_count(),"bigrams":model.bigram_count()});
    let english = WordList::from_path(data.join("english.tsv"))?;
    let english_entries = english.len();
    let mut emoji = EmojiTable::from_path(source.join("assets/emoji/emoji-zh.tsv"))?;
    emoji.merge(EmojiTable::from_path(source.join("assets/emoji/emoji-en.tsv"))?);
    let mut engine = Engine::new(dictionary)
        .with_language_model(Box::new(model)).with_english(english).with_emoji(emoji);
    engine.set_extra_dictionaries(vec![general, idioms]);
    engine.set_shuangpin(Some(Scheme::Xiaohe));
    engine.set_learning(false); // actual upstream option; NoLearner also remains installed
    engine.set_hold_selections(true);
    let load_ms = started.elapsed().as_secs_f64() * 1000.0;
    let config = json!({
        "id":"Q0", "scheme":"xiaohe", "build":"release opt-level=3",
        "data_tag":"data-v8", "dictionary_entries":dictionary_entries,
        "extra_dictionaries":extras, "statistical_model":model_info,
        "english_entries":english_entries, "emoji":"bundled zh+en; core default limits",
        "translation":false, "cloud":false, "neural":false, "learning":false,
        "learning_control":"Engine::set_learning(false) + default NoLearner; no personal state loaded",
        "held_selections":true,"candidate_limit":10,
        "candidate_order":"core eager query().candidates.items; no frontend reorder",
        "frontend":"dispatch ASCII to push/backspace/clear/commit/take_raw; retain visible candidate objects; core owns buffer and held",
        "load_boundary":"data open/mmap/validation, english+emoji parse and Engine assembly through configuration; excludes process startup and JSON",
        "timing":"process includes key/state mutation and query/sort; collect includes top-ten materialization+copy and marked/state extraction; excludes JSON and IPC",
        "reset":"clear + break_chain + enter_input_box; static data not reloaded",
        "preedit_fallback":"parse error: core held_text + actual composition.text",
        "deviations":["Xiaohe instead of default full pinyin","No translators/glossaries, cloud, neural models or downloads",
            "No personal learner, usage/vocabulary/panel meters, input logging, system text replacements or custom phrases",
            "No native host/front-end layout, paging, highlight movement, aux-code or punctuation UI; only requested ASCII subset + Return",
            "Ten core candidates exposed in stable order, independent of native page size"],
        "user_state":"none: no installed Qingjian paths read or written",
    });
    let stdout = io::stdout();
    let mut out = stdout.lock();
    writeln!(out,"{}",json!({"ready":true,"engine":"qingjian-core","id":"Q0","version":VERSION,"load_ms":load_ms,"config":config}))?;
    out.flush()?;
    let mut worker = Worker { engine, visible:Vec::new() };
    for line in io::stdin().lock().lines() {
        let line = line?;
        let request = match serde_json::from_str::<Value>(&line) {
            Ok(request) => request,
            Err(error) => {
                eprintln!("invalid JSON: {error}");
                // The invalid request still gets a complete state response.
                let mut response = worker.respond(&Value::Null);
                response["error"] = json!(format!("invalid JSON: {error}"));
                writeln!(out,"{response}")?;
                out.flush()?;
                continue;
            }
        };
        if request["op"] == "quit" {
            writeln!(out,"{}",json!({"ok":true,"quit":true}))?;
            out.flush()?;
            break;
        }
        writeln!(out,"{}",worker.respond(&request))?;
        out.flush()?;
    }
    Ok(())
}
