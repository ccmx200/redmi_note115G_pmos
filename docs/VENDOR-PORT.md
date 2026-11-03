# Vendor (Android) kernel reference for evergo

Cloned https://github.com/ccmx200/kernel-lxc-xiaomi_mt6833 (branch `resukisu`) via
the git.yylx.win GitHub accelerator into `/root/android-kernel`
(archive `kernel-lxc-xiaomi_mt6833-resukisu.tar.gz`, 215 MB).

Vendor DT: `arch/arm64/boot/dts/mediatek/evergo.dts` + `mt6833.dts` and the
`mediatek/evergo/cust.dtsi`, `sia81xx.dtsi`, `sc8551.dtsi`, `ln8000.dtsi`,
`irtx_led.dtsi`, `cust_mt6833_touch_nt36672c_1080x2400.dtsi` includes.

## Audio (from vendor mt6833.dts / evergo.dts / sia81xx.dtsi)

```dts
sound: sound {
	compatible = "mediatek,mt6833-mt6359-sound";
	mediatek,audio-codec = <&mt6359_snd>;
	mediatek,platform = <&afe>;
	mtk_spk_i2s_out = <3>;
	mtk_spk_i2s_in = <0>;
	mediatek,speaker-codec {
		sound-dai = <&speaker_amp>;
	};
};

&accdet {
	accdet-mic-vol = <8>;
	accdet-plugout-debounce = <1>;
	accdet-mic-mode = <2>;
	/* full block in evergo.dts:425-453 */
};
```

Speaker amp is a **SIA8109** ("sia81xx.dtsi"):
- `si,sia8109` / type `sia81x9`, reset+OWI on GPIO131,
  pinctrl `sia81xx_gpio_L`, `si,sia81xx_disable_pin = <0>`, channel 1.
- right channel (SIA8152) is commented out on evergo.
- audio DAI <&speaker_amp> is referenced by the sound card, so a mainline
  speaker-amp codec driver (or an ASoC wrapper around SIA8109) is required.

## Haptics (vendor evergo.dts)

`aw8697_haptic@5a` on **i2c9**, compatible `awinic,aw8697_haptic`,
reset-gpio GPIO132, irq-gpio GPIO6, plus efuse tables (vib_f0_pre=1700 etc.).
Mainline has `aw86927.c` (same family) — check whether it can bind to
`awinic,aw8697_haptic` or needs a small compatible addition.

## Charger / PMIC (vendor evergo.dts)

- `&mt6360_pmu`: `mt6360,intr_gpio_num = <10>`, intr_gpio `<&pio 10 0>`
- `&mt6360_typec`: intr GPIO 9
- `&mt6360_pmic`, `&mt6360_ldo` (same as stock DTB)
- MT6359 fuel gauge node `mt6359_gauge { compatible = "mediatek,mt6359_gauge"; }`
  (vendor only; no mainline driver yet)
- extra charger ICs: `sc8551.dtsi` (SC8551), `ln8000.dtsi` (LN8000)
- flashlight: `flashlights_mt6360` + `mt6360_pmu_fled` (mainline `leds-mt6360.c`
  + `mt6360_charger.c` exist)
- vibrator legacy node `vibrator0: vibrator@0 { compatible = "mediatek,vibrator"; }`

## Next porting steps

1. Audio: port ASoC machine driver `mt6833-mt6359` (a22x patches 0032/0043),
   mt8192 AFE mt6833 support, `clk-mt6833-audsys`, accdet OF match; add DTS
   nodes (afe/mt6359_snd/sound/accdet/speaker_amp) and UCM rules.
2. Haptics: AW8697 (i2c9 @0x5a, gpio 132/6) with mainline aw86927 or vendor
   driver port.
3. Charger/battery: mt6360 mfd+charger+flash DTS (i2c bus from vendor mt6833.dts,
   intr GPIO10/9), MT6359 fuel gauge (vendor driver or simple voltage-based).
4. Sensors: locate vendor sensor nodes (search vendor tree for
   `gsensor`/`msensor`/`alsps`/`stk`/`mn789` names — evergo.dts itself has no
   explicit I2C sensor nodes; they live in the vendor `cust.dtsi`).
