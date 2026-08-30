use crate::data_feed::FeedId;
use crate::entities::t::databento::Mbp1Msg;
use market_info_core::instrument::InstrumentId;
use std::collections::HashMap;
use std::marker::PhantomData;
use time::NanoTimestamp;

pub struct Decimal(f64);
impl Decimal {
    pub fn new(a: u64, b: u8) -> Self {
        todo!()
    }
}
mod databento {
    pub type Mbp1Msg = ();
    pub enum RType {
        Mbp1
    }

    impl TryFrom<u8> for RType {
        type Error = ();

        fn try_from(value: u8) -> Result<Self, Self::Error> {
            todo!()
        }
    }

    pub fn parse<T>(bytes: &[u8]) -> T {
        todo!()
    }
}

/*
Databento MBP1 message:
 rtype: u8
 publisher_id: u16
 instrument_id: u32
 ts_event: u64
 price: i64
 size: u32
 action: c_char
 side: c_char
 flags: u8
 depth: u8
 ts_recv: u64
 ts_in_delta: i32
 sequence: u32
 bid_px: i64
 ask_px: i64
 bid_sz: u32
 ask_sz: u32
 bid_ct: u32
 ask_ct: u32
 ts_out: u64
 */

pub trait Mbp1View {
    fn instrument_id(&self) -> InstrumentId;
    fn event_time(&self) -> NanoTimestamp;
    fn observe_time(&self) -> NanoTimestamp;
    fn bid_px(&self) -> Decimal;
    fn bid_size(&self) -> Decimal;
    fn ask_px(&self) -> Decimal;
    fn ask_size(&self) -> Decimal;
}

pub trait Mbp1abc123View: Mbp1View {
    fn rtype(&self) -> u8;
    fn publisher_id(&self) -> u16;
    fn instrument_id(&self) -> u32; // TODO: what do?
    fn ts_event(&self) -> u64;
    fn price(&self) -> i64; // todo: WHAT do
    fn size(&self) -> u32;
    fn action(&self) -> c_char;
    fn side(&self) -> c_char;
    fn flags(&self) -> u8;
    fn depth(&self) -> u8;
    fn ts_recv(&self) -> u64;
    fn ts_in_delta(&self) -> i32;
    fn sequence(&self) -> u32;
    fn bid_px(&self) -> i64;
    fn ask_px(&self) -> i64;
    fn bid_sz(&self) -> u32;
    fn ask_sz(&self) -> u32;
    fn bid_ct(&self) -> u32;
    fn ask_ct(&self) -> u32;
    fn ts_out(&self) -> u64;
}

pub trait FeedHandler {
    type Error: std::error::Error + Send + Sync + 'static;
}

pub trait Mbp1UpdateHandler: FeedHandler {
    fn handle_mbp1_update(&mut self, update: impl Mbp1View) -> Result<(), Self::Error>;
}

pub trait PayloadAdapter {
    type Error;
}

pub trait FeedMessageContext {
    fn feed_id(&self) -> &FeedId;
}

pub trait PayloadConsumer {
    type Adapter: PayloadAdapter;
    type Error;

    fn consume_payload(
        &mut self,
        context: impl FeedMessageContext,
        bytes: &[u8],
        adapter: Self::Adapter,
    ) -> Result<(), Self::Error>;
}

pub const DATABENTO_PRICE_SCALE: u8 = 9;

pub struct DatabentoMbp1Msg {
    pub msg: databento::Mbp1Msg,
    pub instrument_id: InstrumentId,
}

impl Mbp1View for DatabentoMbp1Msg {
    fn instrument_id(&self) -> InstrumentId {
        self.instrument_id
    }

    fn event_time(&self) -> NanoTimestamp {
        NanoTimestamp(self.msg.hd.ts_event)
    }
    fn observe_time(&self) -> NanoTimestamp {
        NanoTimestamp(self.msg.rec.ts_recv)
    }
    fn bid_px(&self) -> Decimal {
        Decimal::new(self.rec.levels[0].bid_px, DATABENTO_PRICE_SCALE)
    }
    fn bid_size(&self) -> Decimal {
        Decimal::new(self.rec.levels[0].bid_sz, 0)
    }
    fn ask_px(&self) -> Decimal {
        Decimal::new(self.rec.levels[0].ask_px, DATABENTO_PRICE_SCALE)
    }
    fn ask_size(&self) -> Decimal {
        Decimal::new(self.rec.levels[0].ask_sz, 0)
    }
}

impl Mbp1abc123View for DatabentoMbp1Msg {
    todo!();
}

pub trait DatabentoAdapter: PayloadAdapter {
    type Handler: Mbp1UpdateHandler;

    fn on_mbp1(
        &mut self,
        context: impl FeedMessageContext,
        msg: databento::Mbp1Msg,
    ) -> Result<(), Self::Error>;
}


pub struct DatabentoPayloadAdapter<'a, H> {
    instrument_lookup_table: &'a HashMap<u32, InstrumentId>,
    handler: &'a mut H,
}

impl<H> PayloadAdapter for DatabentoPayloadAdapter<H> {
    type Error = ();
}

impl<H> DatabentoAdapter for DatabentoPayloadAdapter<'_, H>
where
    H: Mbp1UpdateHandler
{
    type Handler = H;

    fn on_mbp1(&mut self, context: impl FeedMessageContext, msg: Mbp1Msg) -> Result<(), Self::Error> {
        let Some(instrument_id) = self.instrument_lookup_table.get(&msg.rec.hd.instrument_id) else {
            return Ok(());
        };
        let mbp1 = DatabentoMbp1Msg { msg: msg.clone(), instrument_id: instrument_id.clone() };
        self.handler.handle_mbp1_update(mbp1)
    }
}

pub struct DatabentoPayloadConsumer<A> {
    _adapter: PhantomData<A>,
}

impl<A> PayloadConsumer for DatabentoPayloadConsumer<A>
where
    A: DatabentoAdapter,
{
    type Adapter = A;
    type Error = ();

    fn consume_payload(
        &mut self,
        context: impl FeedMessageContext,
        bytes: &[u8],
        adapter: &mut Self::Adapter,
    ) -> Result<(), Self::Error> {
        let rtype = *bytes.get(1).ok_or(DecodeError::Malformed("short header"))?;
        match databento::RType::try_from(rtype) {
            Ok(databento::RType::Mbp1) => {
                let msg: Mbp1Msg = databento::parse(bytes)?;
                adapter.on_mbp1(context, msg)
            }
            _ => todo!()
        }
    }
}

