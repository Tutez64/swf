package swf.exporters.animate;

#if (lime && !flash && swf_hardware_bitmap_cache)
import lime.graphics.cairo.CairoFormat;
import lime.graphics.cairo.CairoImageSurface;
import lime.utils.Bytes;
import openfl.display.BitmapData;
import openfl.display.BitmapDataChannel;
import openfl.display.BlendMode;
import openfl.display.IBitmapDrawable;
import openfl.display.StageQuality;
import openfl.display3D.Context3D;
import openfl.display3D.textures.TextureBase;
import openfl.events.Event;
import openfl.filters.BitmapFilter;
import openfl.geom.ColorTransform;
import openfl.geom.Matrix;
import openfl.geom.Point;
import openfl.geom.Rectangle;
import openfl.utils.ByteArray;
import openfl.utils.Object;
import openfl.Vector;

/**
	A bitmap of an Animate library that keeps its pixels on the GPU, and
	decodes its image when it is asked for instead of when a symbol that uses
	it is created: for a texture when it is first drawn, and again if the
	texture is lost; for the software renderer, as `BitmapData.draw()` into a
	readable bitmap uses, in a copy that is let go once it is no longer drawn.

	It is `readable`, since its pixels can always be had. A method that reads
	or writes them makes it an ordinary bitmap, which keeps its image.
**/
#if !openfl_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:access(openfl.display.BitmapData)
@:access(openfl.display._internal.CairoGraphics)
@:access(openfl.display3D.Context3D)
@:access(swf.exporters.animate.AnimateLibrary)
class AnimateHardwareBitmapData extends BitmapData
{
	private var __library:AnimateLibrary;
	private var __symbol:AnimateBitmapSymbol;
	// AnimateLibrary's clock when a texture was last asked for
	private var __lastUsed:Float = 0;
	// Its pixels were read or written by a method: it keeps its image, as any bitmap
	private var __ordinary:Bool = false;
	// The decoded copy the software renderer draws from, and when it was last asked for
	private var __softwareCopy:BitmapData;
	private var __softwareCopyUsed:Float = 0;

	// Cairo draws a bitmap from the surface it gives. The canvas renderer reads its image, which only an ordinary bitmap has
	private static inline var SOFTWARE_RENDERER:Bool = #if lime_cairo true #else false #end;
	// The seconds a copy for the software renderer is kept after it was last drawn
	private static inline var SOFTWARE_COPY_IDLE_TIME:Float = 2;

	private static var __softwareCopies:Array<AnimateHardwareBitmapData> = [];
	private static var __softwareCopiesListening:Bool = false;
	// What a hit test is given: it reads the outline of a fill, not its pixels
	private static var __hitTestSurface:CairoImageSurface;

	private function new(library:AnimateLibrary, symbol:AnimateBitmapSymbol, width:Int, height:Int)
	{
		super(0, 0, true, 0);

		__library = library;
		__symbol = symbol;

		this.width = width;
		this.height = height;
		rect = new Rectangle(0, 0, width, height);

		__textureWidth = width;
		__textureHeight = height;

		__isValid = true;
		// The software renderer skips a bitmap that says it is not
		readable = SOFTWARE_RENDERER;
	}

	/**
		A bitmap for the symbol, or null when its size cannot be told without
		decoding it: the library does not hold its encoded image, or it is
		not a PNG or JPEG file.
	**/
	@:allow(swf.exporters.animate.AnimateLibrary)
	private static function create(library:AnimateLibrary, symbol:AnimateBitmapSymbol):AnimateHardwareBitmapData
	{
		if (symbol.path == null)
		{
			return null;
		}

		var bytes = library.__getEncodedImage(symbol.path);

		if (bytes == null || (symbol.alpha != null && library.__getEncodedImage(symbol.alpha) == null))
		{
			return null;
		}

		var size = readSize(bytes);
		return size != null ? new AnimateHardwareBitmapData(library, symbol, size[0], size[1]) : null;
	}

	/**
		The width and height a PNG or JPEG file gives in its header, or null.
	**/
	@:allow(swf.exporters.animate.AnimateLibrary)
	private static function readSize(bytes:Bytes):Array<Int>
	{
		var length = bytes.length;
		var width = 0;
		var height = 0;

		if (length >= 24 && bytes.get(0) == 0x89 && bytes.get(1) == 0x50 && bytes.get(2) == 0x4E && bytes.get(3) == 0x47)
		{
			// The IHDR chunk comes first
			width = (bytes.get(16) << 24) | (bytes.get(17) << 16) | (bytes.get(18) << 8) | bytes.get(19);
			height = (bytes.get(20) << 24) | (bytes.get(21) << 16) | (bytes.get(22) << 8) | bytes.get(23);
		}
		else if (length >= 4 && bytes.get(0) == 0xFF && bytes.get(1) == 0xD8)
		{
			var position = 2;

			while (position + 8 < length && bytes.get(position) == 0xFF)
			{
				var marker = bytes.get(position + 1);

				if (marker == 0xFF)
				{
					// Padding before a marker
					position++;
				}
				else if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8))
				{
					// No segment follows these
					position += 2;
				}
				else if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
				{
					// A frame header
					height = (bytes.get(position + 5) << 8) | bytes.get(position + 6);
					width = (bytes.get(position + 7) << 8) | bytes.get(position + 8);
					break;
				}
				else if (marker == 0xD9 || marker == 0xDA)
				{
					break;
				}
				else
				{
					position += 2 + ((bytes.get(position + 2) << 8) | bytes.get(position + 3));
				}
			}
		}

		return width > 0 && height > 0 ? [width, height] : null;
	}

	public override function clone():BitmapData
	{
		if (__ordinary || !__isValid)
		{
			return super.clone();
		}

		// A bitmap of its own, which decodes the image for itself when it is drawn or read
		var bitmapData = new AnimateHardwareBitmapData(__library, __symbol, width, height);
		bitmapData.__worldTransform.copyFrom(__worldTransform);
		bitmapData.__renderTransform.copyFrom(__renderTransform);
		return bitmapData;
	}

	public override function getTexture(context:Context3D):TextureBase
	{
		if (__ordinary)
		{
			return super.getTexture(context);
		}

		if (image == null && __isValid && (__texture == null || __textureContext != context.__context))
		{
			__decodeImage();
		}

		__lastUsed = AnimateLibrary.__hardwareBitmapClock;

		// The upload lets go of the image of a bitmap that is not readable
		readable = false;
		var texture = super.getTexture(context);
		readable = __isValid && SOFTWARE_RENDERER;
		return texture;
	}

	/**
		What the software renderer draws this bitmap from: a decoded copy,
		kept while it is drawn.
	**/
	public override function getSurface():CairoImageSurface
	{
		#if lime_cairo
		if (!__ordinary && __isValid)
		{
			if (__softwareCopy == null && openfl.display._internal.CairoGraphics.hitTesting)
			{
				if (__hitTestSurface == null)
				{
					__hitTestSurface = new CairoImageSurface(CairoFormat.ARGB32, 1, 1);
				}

				return __hitTestSurface;
			}

			if (__softwareCopy == null)
			{
				__softwareCopy = BitmapData.fromImage(__library.__decodeHardwareImage(__symbol), transparent);

				if (__softwareCopy == null)
				{
					return null;
				}

				__softwareCopies.push(this);

				if (!__softwareCopiesListening)
				{
					__softwareCopiesListening = true;
					openfl.Lib.current.addEventListener(Event.ENTER_FRAME, __onSoftwareCopiesFrame);
				}
			}

			__softwareCopyUsed = haxe.Timer.stamp();
			return __softwareCopy.getSurface();
		}
		#end

		return super.getSurface();
	}

	private static function __onSoftwareCopiesFrame(_:Event):Void
	{
		__releaseIdleSoftwareCopies(haxe.Timer.stamp() - SOFTWARE_COPY_IDLE_TIME);

		if (__softwareCopies.length == 0)
		{
			__softwareCopiesListening = false;
			openfl.Lib.current.removeEventListener(Event.ENTER_FRAME, __onSoftwareCopiesFrame);
		}
	}

	/**
		Lets go of the copies for the software renderer that were last drawn
		before `time`, and returns how many are left.
	**/
	@:allow(swf.exporters.animate.AnimateLibrary)
	private static function __releaseIdleSoftwareCopies(time:Float):Int
	{
		var index = __softwareCopies.length;

		while (--index >= 0)
		{
			var bitmapData = __softwareCopies[index];

			if (bitmapData.__softwareCopy == null || bitmapData.__softwareCopyUsed <= time)
			{
				bitmapData.__releaseSoftwareCopy();
				__softwareCopies.splice(index, 1);
			}
		}

		return __softwareCopies.length;
	}

	private function __releaseSoftwareCopy():Void
	{
		if (__softwareCopy != null)
		{
			__softwareCopy.dispose();
			__softwareCopy = null;
		}
	}

	/**
		Disposes of the texture if none was asked for in the last `idleTime`
		seconds. The next draw decodes the image and uploads it again.
	**/
	@:allow(swf.exporters.animate.AnimateLibrary)
	private function __releaseIdleTexture(idleTime:Float):Bool
	{
		if (__ordinary || __texture == null || AnimateLibrary.__hardwareBitmapClock - __lastUsed < idleTime)
		{
			return false;
		}

		__texture.dispose();
		__texture = null;
		return true;
	}

	public override function dispose():Void
	{
		__releaseSoftwareCopy();
		super.dispose();
	}

	public override function disposeImage():Void
	{
		// An ordinary bitmap again goes back to its texture alone
		if (__ordinary)
		{
			super.disposeImage();
		}
	}

	/**
		Makes this an ordinary bitmap, with its image decoded and kept: what a
		method that reads or writes its pixels works on.
	**/
	private function __makeOrdinary():Void
	{
		if (__ordinary || !__isValid)
		{
			return;
		}

		__ordinary = true;
		__releaseSoftwareCopy();

		if (image == null)
		{
			var decoded = __library.__decodeHardwareImage(__symbol);

			if (decoded != null && decoded.buffer != null)
			{
				__fromImage(decoded);
			}
			else
			{
				// Nothing to read: as a bitmap whose image was disposed of
				readable = false;
			}
		}
	}

	private function __decodeImage():Void
	{
		var decoded = __library.__decodeHardwareImage(__symbol);

		if (decoded != null && decoded.buffer != null)
		{
			// The texture's upload releases the image again
			__fromImage(decoded);
		}
	}

	// The methods that read or write the pixels

	public override function applyFilter(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, filter:BitmapFilter):Void
	{
		__makeOrdinary();
		super.applyFilter(sourceBitmapData, sourceRect, destPoint, filter);
	}

	public override function colorTransform(rect:Rectangle, colorTransform:ColorTransform):Void
	{
		__makeOrdinary();
		super.colorTransform(rect, colorTransform);
	}

	public override function compare(otherBitmapData:BitmapData):Dynamic
	{
		__makeOrdinary();
		return super.compare(otherBitmapData);
	}

	public override function copyChannel(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, sourceChannel:BitmapDataChannel,
			destChannel:BitmapDataChannel):Void
	{
		__makeOrdinary();
		super.copyChannel(sourceBitmapData, sourceRect, destPoint, sourceChannel, destChannel);
	}

	public override function copyPixels(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, alphaBitmapData:BitmapData = null,
			alphaPoint:Point = null, mergeAlpha:Bool = false):Void
	{
		__makeOrdinary();
		super.copyPixels(sourceBitmapData, sourceRect, destPoint, alphaBitmapData, alphaPoint, mergeAlpha);
	}

	public override function draw(source:IBitmapDrawable, matrix:Matrix = null, colorTransform:ColorTransform = null, blendMode:BlendMode = null,
			clipRect:Rectangle = null, smoothing:Bool = false):Void
	{
		__makeOrdinary();
		super.draw(source, matrix, colorTransform, blendMode, clipRect, smoothing);
	}

	public override function drawWithQuality(source:IBitmapDrawable, matrix:Matrix = null, colorTransform:ColorTransform = null, blendMode:BlendMode = null,
			clipRect:Rectangle = null, smoothing:Bool = false, quality:StageQuality = null):Void
	{
		__makeOrdinary();
		super.drawWithQuality(source, matrix, colorTransform, blendMode, clipRect, smoothing, quality);
	}

	public override function encode(rect:Rectangle, compressor:Object, byteArray:ByteArray = null):ByteArray
	{
		__makeOrdinary();
		return super.encode(rect, compressor, byteArray);
	}

	public override function fillRect(rect:Rectangle, color:Int):Void
	{
		__makeOrdinary();
		super.fillRect(rect, color);
	}

	public override function floodFill(x:Int, y:Int, color:Int):Void
	{
		__makeOrdinary();
		super.floodFill(x, y, color);
	}

	public override function getColorBoundsRect(mask:Int, color:Int, findColor:Bool = true):Rectangle
	{
		__makeOrdinary();
		return super.getColorBoundsRect(mask, color, findColor);
	}

	public override function getPixel(x:Int, y:Int):Int
	{
		__makeOrdinary();
		return super.getPixel(x, y);
	}

	public override function getPixel32(x:Int, y:Int):Int
	{
		__makeOrdinary();
		return super.getPixel32(x, y);
	}

	public override function getPixels(rect:Rectangle):ByteArray
	{
		__makeOrdinary();
		return super.getPixels(rect);
	}

	public override function getVector(rect:Rectangle):Vector<UInt>
	{
		__makeOrdinary();
		return super.getVector(rect);
	}

	public override function histogram(hRect:Rectangle = null):Array<Array<Int>>
	{
		__makeOrdinary();
		return super.histogram(hRect);
	}

	public override function hitTest(firstPoint:Point, firstAlphaThreshold:Int, secondObject:Object, secondBitmapDataPoint:Point = null,
			secondAlphaThreshold:Int = 1):Bool
	{
		__makeOrdinary();
		return super.hitTest(firstPoint, firstAlphaThreshold, secondObject, secondBitmapDataPoint, secondAlphaThreshold);
	}

	public override function merge(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, redMultiplier:UInt, greenMultiplier:UInt,
			blueMultiplier:UInt, alphaMultiplier:UInt):Void
	{
		__makeOrdinary();
		super.merge(sourceBitmapData, sourceRect, destPoint, redMultiplier, greenMultiplier, blueMultiplier, alphaMultiplier);
	}

	public override function noise(randomSeed:Int, low:Int = 0, high:Int = 255, channelOptions:Int = 7, grayScale:Bool = false):Void
	{
		__makeOrdinary();
		super.noise(randomSeed, low, high, channelOptions, grayScale);
	}

	public override function paletteMap(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, redArray:Array<Int> = null,
			greenArray:Array<Int> = null, blueArray:Array<Int> = null, alphaArray:Array<Int> = null):Void
	{
		__makeOrdinary();
		super.paletteMap(sourceBitmapData, sourceRect, destPoint, redArray, greenArray, blueArray, alphaArray);
	}

	public override function perlinNoise(baseX:Float, baseY:Float, numOctaves:UInt, randomSeed:Int, stitch:Bool, fractalNoise:Bool, channelOptions:UInt = 7,
			grayScale:Bool = false, offsets:Array<Point> = null):Void
	{
		__makeOrdinary();
		super.perlinNoise(baseX, baseY, numOctaves, randomSeed, stitch, fractalNoise, channelOptions, grayScale, offsets);
	}

	public override function scroll(x:Int, y:Int):Void
	{
		__makeOrdinary();
		super.scroll(x, y);
	}

	public override function setPixel(x:Int, y:Int, color:Int):Void
	{
		__makeOrdinary();
		super.setPixel(x, y, color);
	}

	public override function setPixel32(x:Int, y:Int, color:Int):Void
	{
		__makeOrdinary();
		super.setPixel32(x, y, color);
	}

	public override function setPixels(rect:Rectangle, byteArray:ByteArray):Void
	{
		__makeOrdinary();
		super.setPixels(rect, byteArray);
	}

	public override function setVector(rect:Rectangle, inputVector:Vector<UInt>):Void
	{
		__makeOrdinary();
		super.setVector(rect, inputVector);
	}

	public override function threshold(sourceBitmapData:BitmapData, sourceRect:Rectangle, destPoint:Point, operation:String, threshold:Int,
			color:Int = 0x00000000, mask:Int = 0xFFFFFFFF, copySource:Bool = false):Int
	{
		__makeOrdinary();
		return super.threshold(sourceBitmapData, sourceRect, destPoint, operation, threshold, color, mask, copySource);
	}
}
#end
