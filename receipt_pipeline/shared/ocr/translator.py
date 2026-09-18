"""Local translation via Helsinki-NLP OPUS-MT — free, no API calls.

MVP scope: Swedish only, matching the current trip itinerary. Adding another
source language later is just another entry in MODEL_NAMES.
"""

from functools import lru_cache
from typing import Optional

from transformers import MarianMTModel, MarianTokenizer

MODEL_NAMES = {
    "sv": "Helsinki-NLP/opus-mt-sv-en",
}


@lru_cache(maxsize=2)
def _get_model(source_lang: str):
    model_name = MODEL_NAMES[source_lang]
    tokenizer = MarianTokenizer.from_pretrained(model_name)
    model = MarianMTModel.from_pretrained(model_name)
    return tokenizer, model


def translate(text: str, source_lang: str = "sv") -> Optional[str]:
    """Translates text to English. Returns None if source_lang has no model yet."""
    if source_lang not in MODEL_NAMES:
        return None

    tokenizer, model = _get_model(source_lang)
    batch = tokenizer([text], return_tensors="pt", padding=True)
    generated = model.generate(**batch)
    return tokenizer.decode(generated[0], skip_special_tokens=True)